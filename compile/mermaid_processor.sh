#!/usr/bin/env bash
# =============================================================================
#  mermaid_processor.sh — extract ```mermaid fenced blocks from a Markdown
#  file, render each to a PDF via `mmdc --pdfFit`, and rewrite the block as a
#  normal Markdown image reference pointing at the rendered PDF.
#
#  This is a bash rewrite of the original mermaid_processor.py and preserves
#  its interface and documented behaviour (see compile/README.md).
#
#  Captions
#  --------
#  If a line inside a mermaid fence has the form:
#
#      %% caption: Figure 1: My diagram.
#
#  that text is used as the image alt text, which Pandoc promotes to a figure
#  caption under the `implicit_figures` extension. The first caption line in
#  the block wins; if no caption is given, a generic placeholder is used so
#  that Pandoc still treats the image as a figure.
#
#  Usage
#  -----
#      mermaid_processor.sh input.md output.md --diagrams-dir DIR [--mmdc M]
#                                                 [--strict]
#
#  The original input.md is never modified. output.md is a derived file with
#  mermaid blocks replaced by image links; feed THAT to pandoc.
#
#  Behaviour on failure
#  --------------------
#  By default, a failed mmdc render leaves the original mermaid fence in the
#  output and prints a warning to stderr, so that pandoc still produces a
#  PDF (with a raw code block instead of a diagram). Pass --strict to abort
#  on the first failure instead.
#
#  Notes
#  -----
#  * Image links written into the output Markdown are RELATIVE to the output
#    file's directory, so the document is portable across machines.
#  * Rendered PDFs are cached by content hash. Bump CACHE_VERSION if you
#    change the mmdc invocation (e.g. different --pdfFit options) to
#    invalidate stale caches.
#  * mmdc runs under `timeout` so a hung renderer cannot stall the build.
#  * Fails fast with a clear message if mmdc is missing.
# =============================================================================

set -euo pipefail

# Bump this if you change the mmdc command line so caches are invalidated.
CACHE_VERSION="v3"

MMDC_TIMEOUT_SECONDS=120

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
# result (a whitespace-only line becomes an empty line).
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

# Trim [ \t] runs from both ends of $1 and print the result.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}" # strip leading
    s="${s%"${s##*[![:space:]]}"}" # strip trailing
    printf '%s\n' "$s"
}

usage() {
    cat <<'EOF'
usage: mermaid_processor.sh input.md output.md --diagrams-dir DIR [--mmdc M] [--strict]

Extracts ```mermaid fences, renders them to PDF with mmdc, and rewrites the
fences as Markdown image references. See the header comment for details.
EOF
}

# --- Argument parsing ---------------------------------------------------------

INPUT="" OUTPUT="" DIAGRAMS_DIR="" MMDC="mmdc" STRICT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --diagrams-dir)
            [[ -n "${2:-}" ]] || fatal "--diagrams-dir requires an argument"
            DIAGRAMS_DIR="$2"; shift 2 ;;
        --mmdc)
            [[ -n "${2:-}" ]] || fatal "--mmdc requires an argument"
            MMDC="$2"; shift 2 ;;
        --strict)
            STRICT=1; shift ;;
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

[[ -n "$INPUT" && -n "$OUTPUT" && -n "$DIAGRAMS_DIR" ]] || { usage; exit 2; }
[[ -f "$INPUT" ]] || fatal "input file not found: $INPUT"

# Same check as the Python version: mmcd must be on PATH or exist as a file.
if ! command -v "$MMDC" >/dev/null 2>&1 && [[ ! -e "$MMDC" ]]; then
    cat >&2 <<EOF
mmdc executable not found: $MMDC
Install it with:  npm install -g @mermaid-js/mermaid-cli
EOF
    exit 1
fi

INPUT_A="$(abspath "$INPUT")"
OUTPUT_A="$(abspath "$OUTPUT")"
DIAGRAMS_A="$(abspath "$DIAGRAMS_DIR")"
OUT_DIR="$(dirname "$OUTPUT_A")"
INPUT_NAME="$(basename "$INPUT_A")"
OUT_NAME="$(basename "$OUTPUT_A")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ============================================================================
# Pass 1 — scan the input and split it around ```mermaid fences.
#
# $TMP/pass1.md holds the full text with each ```mermaid opener line replaced
# by a unique marker @@MERMAID_BANK_<n>@@ (n starts at 1). The block body
# (code) is captured verbatim into $TMP/code-<n>.dat, its opener line into
# $TMP/opener-<n>.dat and its closer line into $TMP/closer-<n>.dat. The first
# `%% caption:` line, if any, is stored in $TMP/caption-<n>.dat.
#
# This mirrors the Python regex FENCE_RE semantics: the opener is
# `[ \t]*```mermaid[ \t]*` at line start; the closer is the same leading
# whitespace followed by ``` plus optional [ \t]; the code group includes the
# newline after the last code line, exactly as in the Python version.
# ============================================================================

awk -v tmp="$TMP" '
BEGIN { state = -1 }
{
    if (state == -1) {
        if (match($0, /^[ \t]*```mermaid[ \t]*$/)) {
            ind = substr($0, RSTART, RLENGTH)
            sub(/```mermaid[ \t]*$/, "", ind)
            n++
            print $0 > (tmp "/opener-" n ".dat")
            close(tmp "/opener-" n ".dat")
            print "@@MERMAID_BANK_" n "@@"
            state = n
            hcap = 0
            capfile = tmp "/caption-" n ".dat"
            printf "" > capfile
            close(capfile)
            codef = tmp "/code-" n ".dat"
            printf "" > codef
            close(codef)
        } else {
            print $0
        }
    } else {
        # inside a mermaid fence
        if (index($0, ind) == 1 && substr($0, length(ind) + 1) ~ /^```[ \t]*$/) {
            print $0 > (tmp "/closer-" state ".dat")
            close(tmp "/closer-" state ".dat")
            state = -1
        } else {
            print $0 >> codef
            close(codef)
            if (hcap == 0 && match($0, /^[ \t]*%%[ \t]*caption[ \t]*:[ \t]*(.*)$/)) {
                # The first caption line in the block wins (same as the
                # Python CAPTION_RE.search); a contentless caption is
                # ignored so a later blank one cannot shadow a real one.
                cap = substr($0, RSTART, RLENGTH)
                sub(/^[ \t]*%%[ \t]*caption[ \t]*:[ \t]*/, "", cap)
                gsub(/[ \t]*$/, "", cap)
                hcap = 1
                if (length(cap) > 0) {
                    print cap > capfile
                    close(capfile)
                }
            }
        }
    }
}
' "$INPUT" > "$TMP/pass1.md"

NBLOCKS=$(grep -c '^@@MERMAID_BANK_[0-9][0-9]*@@$' "$TMP/pass1.md" || true)

if [[ "$NBLOCKS" -eq 0 ]]; then
    mkdir -p "$(dirname "$OUTPUT_A")"
    safe_install "$INPUT" "$OUTPUT"
    echo "No mermaid blocks found in $INPUT_NAME; copied unchanged."
    exit 0
fi

# ============================================================================
# Pass 2 — render each block via mmdc (cached by content hash) and write a
# per-block result record consumed by pass 3:
#
#   $TMP/status-<n>.dat  contains "ok" or "fail"
#   $TMP/path-<n>.dat    contains the (relative) path to the PDF if ok
# ============================================================================

mkdir -p "$DIAGRAMS_A"

rendered=0
failed=0

for n in $(seq 1 "$NBLOCKS"); do
    codef="$TMP/code-$n.dat"
    dig="$( { printf '%s\0' "$CACHE_VERSION"; cat "$codef"; } | sha256sum | cut -c1-16 )"
    pdf="$DIAGRAMS_A/mermaid-$dig.pdf"
    mmd="$DIAGRAMS_A/mermaid-$dig.mmd"

    if [[ -f "$pdf" ]]; then
        printf 'ok\n' > "$TMP/status-$n.dat"
        rendered=$((rendered + 1))
    else
        cp "$codef" "$mmd"

        set +e
        timeout "$MMDC_TIMEOUT_SECONDS" "$MMDC" --pdfFit \
            --input "$mmd" --output "$pdf" \
            >/dev/null 2>"$TMP/mmdc-err.dat"
        rc=$?
        set -e

        if [[ "$rc" -eq 0 ]]; then
            rm -f "$mmd"
            printf 'ok\n' > "$TMP/status-$n.dat"
            rendered=$((rendered + 1))
        else
            # mmdc failed or timed out: clean up partial outputs and decide
            # whether the build can continue (non-strict) or must abort.
            rm -f "$mmd" "$pdf"
            if [[ "$rc" -eq 124 ]] || [[ "$rc" -eq 137 ]]; then
                errmsg="mmdc timed out after ${MMDC_TIMEOUT_SECONDS}s for block ${dig}"
            else
                errtext="$(trim "$(cat "$TMP/mmdc-err.dat" || true)")"
                errmsg="mmdc failed for block hash ${dig}:
${errtext}"
            fi

            if [[ "$STRICT" -eq 1 ]]; then
                echo "ERROR: $errmsg" >&2
                exit 1
            fi
            echo "WARNING: $errmsg" >&2
            echo "         leaving mermaid block unchanged in $OUT_NAME" >&2
            printf 'fail\n' > "$TMP/status-$n.dat"
            failed=$((failed + 1))
        fi
    fi

    if [[ -f "$pdf" ]]; then
        if rel="$(realpath --relative-to="$OUT_DIR" "$pdf" 2>/dev/null)"; then
            :
        else
            rel="$pdf"  # no realpath available: fall back to absolute
        fi
        printf '%s\n' "$rel" | trim_line > "$TMP/path-$n.dat"
    fi
done

# ============================================================================
# Pass 3 — rebuild the final Markdown: markers are replaced by the image
# link (on success) or by the original verbatim fence (on failure). Failed
# blocks print opener + code + closer exactly as the Python regex group(0).
# ============================================================================

awk -v tmp="$TMP" '
function read_trim(path,    l, res) {
    res = ""
    if ((getline l < path) > 0) {
        gsub(/^[ \t]+|[ \t]+$/, "", l)
        res = l
    }
    close(path)
    return res
}
function dump_block(idx,    l, o, c, cl) {
    # Original fence verbatim: opener line, then code, then closer line.
    # (Note: build the paths in plain variables first — gawk does not parse
    # a concatenation expression inline inside `getline l < ...`.)
    o = tmp "/opener-" idx ".dat"
    c = tmp "/code-" idx ".dat"
    cl = tmp "/closer-" idx ".dat"
    while ((getline l < o) > 0) print l
    close(o)
    while ((getline l < c) > 0) print l
    close(c)
    while ((getline l < cl) > 0) print l
    close(cl)
}
BEGIN { rendered = 0 }
{
    if (match($0, /^@@MERMAID_BANK_[0-9]+@@$/)) {
        mstr = substr($0, RSTART, RLENGTH)
        sub(/^@@MERMAID_BANK_/, "", mstr)
        sub(/@@$/, "", mstr)
        idx = mstr + 0
        if (read_trim(tmp "/status-" idx ".dat") == "ok") {
            rendered++
            alt = read_trim(tmp "/caption-" idx ".dat")
            if (alt == "") alt = "Mermaid diagram " rendered
            print "![" alt "](" read_trim(tmp "/path-" idx ".dat") ")"
            next
        }
        dump_block(idx)
        next
    }
    print
}
' "$TMP/pass1.md" > "$TMP/decoded.md"

mkdir -p "$(dirname "$OUTPUT_A")"
cp "$TMP/decoded.md" "$OUTPUT"

# Summary line, matching the Python version.
MSG="$INPUT_NAME: replaced $rendered mermaid block(s) -> $OUT_NAME"
if [[ "$failed" -gt 0 ]]; then
    MSG="$MSG ($failed failed, left as code blocks)"
fi
echo "$MSG"
