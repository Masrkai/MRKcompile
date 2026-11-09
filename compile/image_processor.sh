#!/usr/bin/env bash
# =============================================================================
#  image_processor.sh — download remote http(s) images referenced in a
#  Markdown file and rewrite the references to local, relative paths in a
#  persistent cache.
#
#  This is a bash rewrite of the original image_processor.py and preserves
#  its interface and documented behaviour (see compile/README.md).
#
#  Why (Typst cannot fetch remote URLs)
#  ------------------------------------
#  Any `![alt](https://...)` must be backed by a local file before pandoc
#  runs, so each remote image is downloaded once into a content-addressed
#  cache and the reference is rewritten to a relative local path.
#
#  Security posture (tighter than the Python version it replaces)
#  --------------------------------------------------------------
#  * HTTPS only by default: an http:// URL is refused loudly and the
#    reference is left untouched. Set ALLOW_HTTP=1 to explicitly permit
#    insecure plaintext downloads for edge cases.
#  * Protocol allowlisting is enforced a second time *inside curl*
#    (`--proto`, `--proto-redir`), so redirects can never leave the allowed
#    schemes (no file://, ftp://, smb://, gopher://, … via redirect).
#  * File names never contain URL text: the cache key is the SHA-256 of the
#    URL and the extension comes from a fixed whitelist. A hostile URL or a
#    hostile server response therefore cannot influence the destination path
#    (no traversal, no command substitution, no unquoted expansion).
#  * Downloads are bounded: `--max-filesize`, a hard post-download size
#    check, `--max-time` and `--connect-timeout` stop a server from
#    exhausting disk or stalling the build. Server-reported sizes on
#    chunked/non-content-length responses cannot evade the post-check.
#  * Redirects are limited (`--max-redirs`) and TLS verification stays on
#    (no --insecure anywhere; failures abort the transfer).
#  * The response body is fetched with `-o` into a temporary file. It is
#    never evaluated, never piped into a shell, and only renamed into the
#    cache after the transfer succeeds atomically.
#  * Only one request is ever made per unique URL per build (cached by URL
#    hash afterwards).
#  * Failures leave the original reference untouched and print a warning to
#    stderr; the build then fails loudly at the typst stage ("file not
#    found") instead of silently dropping the image.
#
#  Caching
#  -------
#  Downloads are cached by URL hash, so repeated builds do not re-fetch.
#  Delete the cache directory to force a re-download.
#
#  Scope
#  -----
#  Only `![alt](url "title")` Markdown image syntax is handled; raw HTML
#  `<img>` tags are out of scope (same as the Python version).
#
#  Usage
#  -----
#      image_processor.sh input.md output.md --cache-dir DIR [--timeout N]
# =============================================================================

set -euo pipefail

DOWNLOAD_TIMEOUT_SECONDS=30

# Hard cap per downloaded file (bytes).curl's --max-filesize can be evaded by
# responses without a Content-Length (chunked), so the post-download check
# below re-enforces this limit.
MAX_FILESIZE_BYTES=$((20 * 1024 * 1024))
MAX_REDIRS=5
UA="MRKcompile-build/1.0"

# --- Helpers -----------------------------------------------------------------

# Print an error and exit non-zero.
fatal() {
    echo "ERROR: $*" >&2
    exit 1
}

# Print $1 as an absolute path (relative paths resolve against the cwd).
abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s\n' "$PWD/$1" ;;
    esac
}

# Trim [ \t] runs from both ends of the line read on stdin and print the
# result.
trim_line() {
    awk '{ gsub(/^[ \t]+/, ""); gsub(/[ \t]+$/, ""); print }'
}

# Install (copy) the file $1 to $2; a no-op when src and dst are the same
# existing file (the pipeline legitimately preprocesses a file in place).
safe_install() {
    local src dst
    src="$(realpath -e "$1" 2>/dev/null || printf '%s\n' "$1")"
    dst="$(realpath -e "$2" 2>/dev/null || printf '%s\n' "$2")"
    if [[ -e "$2" && "$src" == "$dst" ]]; then
        return 0
    fi
    cp "$1" "$2"
}

usage() {
    cat <<'EOF'
usage: image_processor.sh input.md output.md --cache-dir DIR [--timeout N]

Downloads remote http(s) images and rewrites the references to local cache
paths. By default only https:// is fetched; set ALLOW_HTTP=1 to allow
plaintext http. See the header comment for the full security rationale.
EOF
}

# Extension for a URL from its path suffix, mirroring the Python
# URL_EXT_RE + urlsplit(url).path logic: query/fragment dropped, accepted
# suffixes whitelist-only, jpeg normalised to jpg, default empty.
url_ext() {
    awk -v u="$1" 'BEGIN {
        split(u, a, /[?#]/)
        p = tolower(a[1])
        e = ""
        if (match(p, /\.(png|jpe?g|gif|svg|webp|avif|bmp)$/)) {
            e = substr(p, RSTART + 1, RLENGTH - 1)
            if (e == "jpeg") e = "jpg"
            print "." e
        }
    }'
}

# Extension for an HTTP Content-Type header value (fixed map; default .png),
# mirroring the Python CONTENT_TYPE_EXT table.
ctype_ext() {
    case "$1" in
        image/png)      echo ".png" ;;
        image/jpeg)     echo ".jpg" ;;
        image/gif)      echo ".gif" ;;
        image/svg+xml)  echo ".svg" ;;
        image/webp)     echo ".webp" ;;
        image/avif)     echo ".avif" ;;
        image/bmp)      echo ".bmp" ;;
        *)              echo ".png" ;;
    esac
}

# --- Argument parsing ---------------------------------------------------------

INPUT="" OUTPUT="" CACHE_DIR="" TIMEOUT="$DOWNLOAD_TIMEOUT_SECONDS"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cache-dir)
            [[ -n "${2:-}" ]] || fatal "--cache-dir requires an argument"
            CACHE_DIR="$2"; shift 2 ;;
        --timeout)
            [[ -n "${2:-}" ]] || fatal "--timeout requires an argument"
            case "$2" in
                ''|*[!0-9]*) fatal "--timeout expects a non-negative integer" ;;
            esac
            TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        -*)
            fatal "unknown option: $1" ;;
        *)
            if [[ -z "$INPUT" ]]; then
                INPUT="$1"
            elif [[ -z "$OUTPUT" ]]; then
                OUTPUT="$1"
            else
                fatal "unexpected argument: $1"
            fi
            shift ;;
    esac
done

[[ -n "$INPUT" && -n "$OUTPUT" && -n "$CACHE_DIR" ]] || { usage; exit 2; }
[[ -f "$INPUT" ]] || fatal "input file not found: $INPUT"

if ! command -v curl >/dev/null 2>&1; then
    cat >&2 <<EOF
curl executable not found on PATH
Install it from your package manager or: https://curl.se/
EOF
    exit 1
fi

# Scheme policy: HTTPS-only unless the maintainer explicitly allows plaintext.
ALLOW_HTTP="${ALLOW_HTTP:-0}"
if [[ "$ALLOW_HTTP" = "1" ]]; then
    PROTO="=http,https"
else
    PROTO="=https"
fi

INPUT_A="$(abspath "$INPUT")"
OUTPUT_A="$(abspath "$OUTPUT")"
CACHE_A="$(abspath "$CACHE_DIR")"
OUT_DIR="$(dirname "$OUTPUT_A")"
INPUT_NAME="$(basename "$INPUT_A")"
OUT_NAME="$(basename "$OUTPUT_A")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ============================================================================
# Pass 1 — collect remote image URLs and their occurrence counts.
#
# Mirrors the Python IMAGE_RE + is_remote logic: `![alt](url "title")`
# with url starting (case-insensitively) with http:// or https://. A URL
# must be the first whitespace-delimited token inside the parentheses; an
# optional title must be a properly quoted string. Malformed instances and
# non-remote URLs are left untouched.
## ============================================================================

printf '' > "$TMP/urls.tsv"
awk -v urlsfile="$TMP/urls.tsv" '
function wsmark(s,    i) {
    for (i = 1; i <= length(s); i++)
        if (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") return i
    return 0
}
{
    line = $0
    while (match(line, /!\[[^]]*\]\([^)]*\)/)) {
        inst = substr(line, RSTART, RLENGTH)
        p = index(inst, "](")                       # alt cannot contain ]
        inner = substr(inst, p + 2, length(inst) - p - 3)
        gsub(/^[ \t]+|[ \t]+$/, "", inner)
        ok = 1
        ws = wsmark(inner)
        if (inner == "") {
            ok = 0
        } else if (ws == 0) {
            url = inner
        } else {
            url = substr(inner, 1, ws - 1)
            title = substr(inner, ws + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", title)
            if (title !~ /"[^"]*"$/) ok = 0          # unquoted residue: skip
        }
        if (ok && tolower(url) ~ /^https?:\/\//) print url >> urlsfile
        line = substr(line, RSTART + RLENGTH)
    }
}
' "$INPUT" > /dev/null

# Deduplicate and count occurrences per URL:  <url>\t<count>
sort "$TMP/urls.tsv" | uniq -c \
    | awk '{ n = $1; $1 = ""; sub(/^[ \t]+/, ""); print $0 "\t" n }' > "$TMP/occ.tsv"

TOTAL_REMOTE=0
if [[ -s "$TMP/occ.tsv" ]]; then
    TOTAL_REMOTE="$(awk -F'\t' '{ s += $2 } END { print s+0 }' "$TMP/occ.tsv")"
fi

if [[ "$TOTAL_REMOTE" -eq 0 ]]; then
    mkdir -p "$(dirname "$OUTPUT_A")"
    safe_install "$INPUT" "$OUTPUT"
    echo "No remote images in $INPUT_NAME; copied unchanged."
    exit 0
fi

# ============================================================================
# Pass 2 — download each unique remote URL once (cached by URL hash) and
# record:
#   $TMP/map.tsv    <url>\t<relative path to cached file>   (success only)
#   $TMP/state.tsv  <url>\t<FETCH|CACH|FAIL>               (first decision)
# ============================================================================

printf '' > "$TMP/map.tsv"
printf '' > "$TMP/state.tsv"

mkdir -p "$CACHE_A"

while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "$entry" == *$'\t'* ]] || continue
    # entry format: <url>\t<occurrence count>
    url="${entry%%$'\t'*}"
    occ="${entry##*$'\t'}"

    # --- scheme policy ------------------------------------------------------
    scheme_ok=1
    case "$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')" in
        https://*) scheme_ok=1 ;;
        http://*)  [[ "$ALLOW_HTTP" = "1" ]] && scheme_ok=1 || scheme_ok=0 ;;
        *)         scheme_ok=0 ;;
    esac

    digest="$(printf '%s' "$url" | sha256sum | cut -c1-16)"
    uext="$(url_ext "$url")"
    prov_path="$CACHE_A/img-$digest${uext:-.png}"

    label=""
    cached_path=""

    if [[ "$scheme_ok" -eq 0 ]]; then
        echo "WARNING: could not download $url: non-https scheme is not permitted by default" >&2
        echo "         (set ALLOW_HTTP=1 to allow plaintext http) — leaving reference unchanged" >&2
        label="FAIL"
    elif [[ -e "$prov_path" ]]; then
        label="CACH"
        cached_path="$prov_path"
    else
        # --- download (bounded, atomic, protocol-restricted) ----------------
        body="$TMP/body.bin"
        hdr="$TMP/headers.txt"
        rm -f "$body"

        set +e
        curl -sS --fail \
            --proto "$PROTO" \
            --proto-redir "$PROTO" \
            --max-redirs "$MAX_REDIRS" \
            --location \
            --max-filesize "$MAX_FILESIZE_BYTES" \
            --connect-timeout 10 \
            --max-time "$TIMEOUT" \
            --user-agent "$UA" \
            -o "$body" \
            -D "$hdr" \
            "$url" 2>"$TMP/curl-err.dat"
        rc=$?
        set -e

        # Defense in depth: --max-filesize can be evaded by chunked/no
        # Content-Length responses, so re-check the size of what landed.
        bytes=0
        if [[ -f "$body" ]]; then
            bytes="$(stat -c '%s' "$body" 2>/dev/null || echo 0)"
        fi

        if [[ "$rc" -ne 0 ]]; then
            errtext="$(trim_line "$TMP/curl-err.dat" 2>/dev/null || true)"
            echo "WARNING: could not download $url: curl exit $rc${errtext:+ ($errtext)}" >&2
            echo "         leaving remote reference unchanged in $OUT_NAME" >&2
            label="FAIL"
        elif [[ "$bytes" -gt "$MAX_FILESIZE_BYTES" ]]; then
            echo "WARNING: could not download $url: response exceeds ${MAX_FILESIZE_BYTES} byte limit" >&2
            echo "         leaving remote reference unchanged in $OUT_NAME" >&2
            label="FAIL"
        else
            # Extension: URL suffix wins; otherwise map the Content-Type
            # (strip parameters, lowercase) exactly like the Python code.
            ctype="$(awk '{
                l = tolower($0)
                sub(/^[ ]+/, "", l)
                if (index(l, "content-type:") == 1) {
                    keep = l
                    sub(/^[ ]*content-type:[ ]*/, "", keep)
                    gsub(/[ \t\r]+$/, "", keep)
                    print keep           # remember; the last one wins below
                }
            }' "$hdr" | awk 'END { print }')"
            ctype="${ctype%%;*}"
            ctype="$(printf '%s' "$ctype" | tr '[A-Z]' '[a-z]' | tr -d '[:space:]')"

            extf="$uext"
            [[ -n "$extf" ]] || extf="$(ctype_ext "$ctype")"
            final_path="$CACHE_A/img-$digest$extf"

            if [[ "$final_path" != "$prov_path" && -e "$final_path" ]]; then
                # Same URL already cached under the content-type extension.
                label="CACH"
                cached_path="$final_path"
                rm -f "$body"
            else
                mv "$body" "$final_path"
                label="FETCH"
                cached_path="$final_path"
            fi
        fi
        rm -f "$body"
    fi

    printf '%s\t%s\n' "$url" "$label" >> "$TMP/state.tsv"

    if [[ -n "$cached_path" ]]; then
        if rel="$(realpath --relative-to="$OUT_DIR" "$cached_path" 2>/dev/null)"; then
            :
        else
            rel="$cached_path"   # no realpath available: fall back to absolute
        fi
        printf '%s\t%s\n' "$url" "$rel" >> "$TMP/map.tsv"
    fi
done < "$TMP/occ.tsv"

# ============================================================================
# Pass 3 — rewrite the image references. Each instance uses its own alt text
# and title; the local path comes from the URL-keyed map. Instances whose
# download failed (or that never entered the map) are left untouched, and
# pandoc/typst then fail loudly downstream.
# ============================================================================
awk -v map="$TMP/map.tsv" '
BEGIN {
    while ((getline line < map) > 0) {
        split(line, f, "\t")
        relmap[f[1]] = f[2]
    }
    close(map)
}
function wsmark(s,    i) {
    for (i = 1; i <= length(s); i++)
        if (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") return i
    return 0
}
{
    line = $0
    out = ""
    while (match(line, /!\[[^]]*\]\([^)]*\)/)) {
        inst = substr(line, RSTART, RLENGTH)
        p = index(inst, "](")
        alt = substr(inst, 3, p - 3)
        inner = substr(inst, p + 2, length(inst) - p - 3)
        gsub(/^[ \t]+|[ \t]+$/, "", inner)
        ok = 1
        url = ""
        title = ""
        ws = wsmark(inner)
        if (inner == "") {
            ok = 0
        } else if (ws == 0) {
            url = inner
        } else {
            url = substr(inner, 1, ws - 1)
            title = substr(inner, ws + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", title)
            if (title !~ /"[^"]*"$/) ok = 0
        }
        if (ok && url in relmap) {
            suffix = ""
            if (title != "") suffix = " " title
            inst = "![" alt "](" relmap[url] suffix ")"
        }
        out = out substr(line, 1, RSTART - 1) inst
        line = substr(line, RSTART + RLENGTH)
    }
    print out line
}
' "$INPUT" > "$TMP/decoded.md"

mkdir -p "$(dirname "$OUTPUT_A")"
cp "$TMP/decoded.md" "$OUTPUT"

# Summary line, mirroring the Python counters (per occurrence, not per URL).
fetch_occ=0; cach_occ=0; fail_occ=0
while IFS= read -r s_entry; do
    [[ -n "$s_entry" && "$s_entry" == *$'\t'* ]] || continue
    s_url="${s_entry%$'\t'*}"
    s_label="${s_entry#*$'\t'}"
    occ="$(awk -F'\t' -v u="$s_url" '$1 == u { print $2; exit }' "$TMP/occ.tsv")"
    occ="${occ:-0}"
    case "$s_label" in
        FETCH) fetch_occ=$((fetch_occ + occ)) ;;
        CACH)  cach_occ=$((cach_occ + occ)) ;;
        FAIL)  fail_occ=$((fail_occ + occ)) ;;
    esac
done < "$TMP/state.tsv"

MSG="$INPUT_NAME: $TOTAL_REMOTE remote image(s) -> $OUT_NAME ($fetch_occ downloaded, $cach_occ cached)"
if [[ "$fail_occ" -gt 0 ]]; then
    MSG="$MSG ($fail_occ failed, left as remote references)"
fi
echo "$MSG"
