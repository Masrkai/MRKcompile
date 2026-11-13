#!/usr/bin/env bash
# =============================================================================
#  asset_path_processor.sh — resolve relative asset paths (images, SVGs, ...)
#  in a Markdown file so they can be found by pandoc/typst, which resolve
#  every relative path against the working directory of the build (the root
#  of the resolved/ staging tree), NOT against the document's own location.
#
#  Resolution rule
#  ---------------
#  For a document whose directory is D relative to the project root, a
#  relative image target `url` is resolved as:
#
#    1. D/url exists  -> rewritten to the normalized D/url
#                        (paths written relative to the document's own
#                        directory; this wins when both candidates exist)
#    2. url exists    -> left unchanged
#                        (paths already relative to the project root)
#    3. neither       -> left unchanged, warning printed; the build then
#                        fails loudly at the typst stage ("file not found")
#
#  What is rewritten
#  -----------------
#  Only `![alt](url "title")` Markdown image syntax, mirroring the parser
#  in image_processor.sh. Left untouched:
#    * http(s):// URLs (image_processor.sh's job, later in the pipeline)
#    * #anchors
#    * absolute paths (not supported by the pipeline)
#    * targets containing whitespace, quotes, angle brackets or parentheses
#  Code fences (``` / ~~~) are skipped so example content is not altered;
#  indented code blocks are NOT tracked. Raw HTML <img> is out of scope
#  (same as image_processor.sh).
#
#  Usage
#  -----
#      asset_path_processor.sh input.md output.md --project-root DIR
#
#  input.md is never modified; output.md is a derived file. The project root
#  is the working directory for normal builds and the list file's directory
#  for stitched (-l) builds.
#
#  Behaviour on failure
#  --------------------
#  Missing assets are a warning, not an error (same philosophy as
#  image_processor.sh: the typst stage fails loudly later). Only internal
#  errors (unreadable input, unusable arguments) exit non-zero.
# =============================================================================

set -euo pipefail

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

# Install (copy) the file $1 to $2; a no-op when src and dst are the same
# existing file (the pipeline legitimately preprocesses a file in place).
safe_install() {
    local src dst
    src="$(realpath -e "$1" 2>/dev/null || printf '%s\n' "$1")"
    dst="$(realpath -e "$2" 2>/dev/null || printf '%s\n' "$2")"
    if [[ -e "$dst" && "$src" == "$dst" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
}

usage() {
    cat <<'EOF'
usage: asset_path_processor.sh input.md output.md --project-root DIR

Rewrites relative image targets so they resolve from the project root.
See the header comment for details.
EOF
}

# Collapse a slash path textually: drop empty and "." segments, pop ".."
# against the preceding segment. Prints the normalized path; if the path
# would climb above its base, prints __ESCAPES__ instead.
normalize_rel() {
    local p="$1" seg out
    local -a parts=()
    local oldifs="$IFS"
    set -f
    IFS='/'
    for seg in $p; do
        case "$seg" in
            ''|.) : ;;
            ..)
                if [ "${#parts[@]}" -eq 0 ]; then
                    IFS="$oldifs"
                    set +f
                    printf '%s\n' "__ESCAPES__"
                    return 0
                fi
                unset "parts[$((${#parts[@]}-1))]"
                ;;
            *) parts+=("$seg") ;;
        esac
    done
    IFS='/'
    out="${parts[*]:-}"
    IFS="$oldifs"
    set +f
    printf '%s\n' "$out"
}

# --- Argument parsing ---------------------------------------------------------

INPUT="" OUTPUT="" PROJECT_ROOT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-root)
            [[ -n "${2:-}" ]] || fatal "--project-root requires an argument"
            PROJECT_ROOT="$2"; shift 2 ;;
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

[[ -n "$INPUT" && -n "$OUTPUT" && -n "$PROJECT_ROOT" ]] || { usage; exit 2; }
[[ -f "$INPUT" ]] || fatal "input file not found: $INPUT"

INPUT_A="$(abspath "$INPUT")"
OUTPUT_A="$(abspath "$OUTPUT")"
ROOT_A="$(abspath "$PROJECT_ROOT")"
[[ -d "$ROOT_A" ]] || fatal "project root is not a directory: $ROOT_A"

# D: the input's directory relative to the project root ("" for the root
# itself). A document outside the project root cannot have its assets
# mirrored, so that is a hard error.
INPUT_DIR_REL="$(realpath --relative-to="$ROOT_A" "$(dirname "$INPUT_A")" 2>/dev/null)" \
    || fatal "cannot determine the location of $INPUT relative to $ROOT_A"
[[ "$INPUT_DIR_REL" == "." ]] && INPUT_DIR_REL=""
if [[ "$INPUT_DIR_REL" == ..* ]]; then
    fatal "$INPUT lies outside the project root $ROOT_A; its relative asset paths cannot be resolved"
fi

INPUT_NAME="$(basename "$INPUT_A")"
OUT_NAME="$(basename "$OUTPUT_A")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ============================================================================
# Pass 1 — collect every image target (deduplicated later). The parsing
# mirrors image_processor.sh: `![alt](url "title")` with alt free of `]`,
# url the first whitespace-delimited token inside the parentheses, an
# optional title a properly quoted string. Fenced code blocks are skipped.
# ============================================================================

printf '' > "$TMP/urls.tsv"
awk -v urlsfile="$TMP/urls.tsv" '
function wsmark(s,    i) {
    for (i = 1; i <= length(s); i++)
        if (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") return i
    return 0
}
{
    if ($0 ~ /^[ \t]*(```|~~~)/) { fence = !fence; next }
    if (fence) next
    line = $0
    while (match(line, /!\[[^]]*\]\([^)]*\)/)) {
        inst = substr(line, RSTART, RLENGTH)
        p = index(inst, "](")                       # alt cannot contain ]
        inner = substr(inst, p + 2, length(inst) - p - 2)
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
        if (ok) print url >> urlsfile
        line = substr(line, RSTART + RLENGTH)
    }
}
' "$INPUT" > /dev/null

sort -u "$TMP/urls.tsv" 2>/dev/null > "$TMP/uniq.tsv" || true

# ============================================================================
# Pass 2 — decide, per unique target, whether it must be rewritten:
#   candidate 1: relative to the document's own directory (D/url)
#   candidate 2: already relative to the project root (url)
#   neither:     warn and leave untouched
# Output: $TMP/map.tsv  <url>\t<root-relative path>   (rewrites only)
# ============================================================================

printf '' > "$TMP/map.tsv"
printf '' > "$TMP/warn.tsv"

while IFS= read -r url; do
    [[ -n "$url" ]] || continue

    # Any URL with a scheme is not a local path (http(s):// is
    # image_processor.sh's job); anchors and absolute paths are not
    # portable asset references; ambiguous target syntax is skipped.
    if [[ "$url" == *"://"* ]]; then
        continue
    fi
    case "$url" in
        \#*|/*) continue ;;
        *[[:space:]\"\'\<\>\(\)]*) continue ;;
    esac

    if [[ -n "$INPUT_DIR_REL" ]]; then
        cand1="$INPUT_DIR_REL/$url"
        checked1="$cand1"
    else
        cand1="$url"
        checked1="$url"
    fi
    norm1="$(normalize_rel "$cand1")"

    if [[ "$norm1" != "__ESCAPES__" && -n "$norm1" && -f "$ROOT_A/$norm1" ]]; then
        if [[ "$norm1" != "$url" ]]; then
            printf '%s\t%s\n' "$url" "$norm1" >> "$TMP/map.tsv"
        fi
        continue
    fi

    norm2="$(normalize_rel "$url")"
    if [[ "$norm2" != "__ESCAPES__" && -n "$norm2" && -f "$ROOT_A/$norm2" ]]; then
        continue                     # already project-root-relative: correct
    fi

    printf '%s\t%s\n' "$url" "$checked1" >> "$TMP/warn.tsv"
done < "$TMP/uniq.tsv"

while IFS= read -r entry; do
    [[ "$entry" == *$'\t'* ]] || continue
    url="${entry%%$'\t'*}"
    checked="${entry##*$'\t'}"
    echo "WARNING: asset not found for image ref '$url' in $INPUT_NAME" >&2
    echo "         (checked '$checked' and '$url' relative to the project root)" >&2
    echo "         leaving the reference unchanged; the typst stage will fail loudly" >&2
    echo "         if the file is missing at build time" >&2
done < "$TMP/warn.tsv"

if [[ ! -s "$TMP/map.tsv" ]]; then
    safe_install "$INPUT" "$OUTPUT"
    echo "$INPUT_NAME: no local asset path changes needed."
    exit 0
fi

# ============================================================================
# Pass 3 — rewrite the image references using the map. Parsing and fence
# tracking are identical to pass 1; each rewritten instance keeps its own
# alt text and title.
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
    if ($0 ~ /^[ \t]*(```|~~~)/) { fence = !fence; print; next }
    if (fence) { print; next }
    line = $0
    out = ""
    while (match(line, /!\[[^]]*\]\([^)]*\)/)) {
        inst = substr(line, RSTART, RLENGTH)
        pre = substr(line, 1, RSTART - 1)
        p = index(inst, "](")
        inner = substr(inst, p + 2, length(inst) - p - 2)
        gsub(/^[ \t]+|[ \t]+$/, "", inner)
        ws = wsmark(inner)
        url = ""
        if (inner != "") {
            if (ws == 0) url = inner
            else url = substr(inner, 1, ws - 1)
        }
        if (url in relmap) {
            if (ws == 0) {
                inst = substr(inst, 1, p + 1) relmap[url] ")"
            } else {
                inst = substr(inst, 1, p + 1) relmap[url] " " substr(inner, ws + 1) ")"
            }
        }
        out = out pre inst
        line = substr(line, RSTART + RLENGTH)
    }
    print out line
}
' "$INPUT" > "$OUTPUT"

N_REWRITTEN="$(grep -c . "$TMP/map.tsv" || true)"
echo "$INPUT_NAME: $N_REWRITTEN local asset path(s) rewritten -> $OUT_NAME"
