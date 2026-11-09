#!/usr/bin/env bash
# =============================================================================
#  Build Markdown files into PDFs using pandoc + typst.
#
#  Usage:
#    compile.sh                         build every top-level *.md in cwd
#    compile.sh a.md [b.md ...]         build only the named files
#    compile.sh -l list.txt             stitch and build files listed in list.txt
#    compile.sh -h | --help             show this help and exit
#
#  Pipeline per file (see build_and_convert):
#    1. Run mermaid_processor.py to replace ```mermaid blocks with image refs,
#       writing the resolved copy into resolved/.
#    2. Run image_processor.py to download remote images into the local cache.
#    3. Run pandoc (custom Typst template) with the typst PDF engine.
#       Directive expansion (/toc, /breakpage, /newpage, /pagebreak) and pipe
#       table conversion are pandoc Lua filters (directives_filter.lua,
#       table_filter.lua) running inside pandoc. (Stitched mode additionally
#       passes -M single-toc=true so that /toc exists at most once globally.)
#       -> PDF/<name>.pdf
#
#  Intermediates: by default everything is built inside a temporary directory
#  under .cache/ that is deleted when the script exits. Set KEEP_RESOLVED=1
#  to build into ./resolved and keep it for debugging.
#
#  Environment overrides:
#    META           path to metadata yaml    (default: <Compile>/metadata.yaml)
#    PREAMBLE       path to typst preamble   (default: <Compile>/preamble.typ)
#    TEMPLATE       path to typst template   (default: <Compile>/typst_template.typ)
#    CACHE_DIR      persistent cache root    (default: <cwd>/.cache)
#    DIAGRAMS_DIR   mermaid render cache     (default: $CACHE_DIR/diagrams)
#    IMAGES_DIR     remote image cache       (default: $CACHE_DIR/images)
#    MMDC           path to mmdc             (default: mmdc on PATH)
#    STRICT_MERMAID set to 1 to abort on mmdc failure (default: 0)
#    KEEP_RESOLVED  set to 1 to keep resolved/ for debugging (default: 0)
# =============================================================================
set -euo pipefail

# Locate the Compile directory where the script and assets live
COMPILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"

META="${META:-$COMPILE_DIR/metadata.yaml}"
PREAMBLE="${PREAMBLE:-$COMPILE_DIR/preamble.typ}"
TEMPLATE="${TEMPLATE:-$COMPILE_DIR/typst_template.typ}"
CACHE_DIR="${CACHE_DIR:-$WORK_DIR/.cache}"
DIAGRAMS_DIR="${DIAGRAMS_DIR:-$CACHE_DIR/diagrams}"
IMAGES_DIR="${IMAGES_DIR:-$CACHE_DIR/images}"
MMDC="${MMDC:-mmdc}"
STRICT_MERMAID="${STRICT_MERMAID:-0}"
KEEP_RESOLVED="${KEEP_RESOLVED:-0}"

# --- Small helpers ------------------------------------------------------------

# Print an error and exit non-zero.
fatal() {
    echo "ERROR: $*" >&2
    exit 1
}

# Print its argument with leading/trailing whitespace (space, tab, CR) removed.
# Used for list-file entries; unlike `xargs` it never mangles quotes or
# backslashes.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}" # strip leading
    s="${s%"${s##*[![:space:]]}"}" # strip trailing
    printf '%s\n' "$s"
}

# Print $1 as an absolute path (relative paths resolve against the cwd).
abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s\n' "$PWD/$1" ;;
    esac
}

# --- Usage -------------------------------------------------------------------
usage() {
    cat <<'EOF'
compile.sh — build Markdown files into PDFs using pandoc + typst.

Usage:
  compile.sh                        build every top-level *.md in cwd
  compile.sh a.md [b.md ...]        build only the named files
  compile.sh -l list.txt            stitch and build files listed in list.txt
  compile.sh -h | --help            show this help and exit

Options:
  -l <list.txt>   stitch and build the files listed in <list.txt> as one PDF
                  (list entries may be relative to the list file; '#' comments)
  -h, --help      show this help and exit

Environment overrides:
  META=<path>           path to metadata yaml  (default: <Compile>/metadata.yaml)
  PREAMBLE=<path>       path to typst preamble (default: <Compile>/preamble.typ)
  TEMPLATE=<path>       path to typst template (default: <Compile>/typst_template.typ)
  CACHE_DIR=<path>      persistent cache root  (default: <cwd>/.cache)
  DIAGRAMS_DIR=<path>   mermaid render cache   (default: $CACHE_DIR/diagrams)
  IMAGES_DIR=<path>     remote image cache     (default: $CACHE_DIR/images)
  MMDC=<path>           path to mmdc           (default: mmdc on PATH)
  STRICT_MERMAID=1      abort on mmdc failure  (default: 0, existing diagrams reused)
  KEEP_RESOLVED=1       keep resolved/ for debugging (default: 0)

Output:
  PDF/<name>.pdf. Intermediates are built in a temporary directory under .cache/
  that is deleted on exit; set KEEP_RESOLVED=1 to build into ./resolved instead.
EOF
}

# --- Argument parsing ---------------------------------------------------------
LIST_FILE=""
FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -l)
            [ -n "${2:-}" ] || fatal "-l requires an argument (list file)"
            LIST_FILE="$2"
            shift 2
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            echo "Try --help for usage." >&2
            exit 1
            ;;
        *)
            FILES+=("$1")
            shift
            ;;
    esac
done

# Relative overrides must work from any cwd, and pandoc below runs from inside
# resolved/ — so absolutize the asset paths up front, before any `cd`.
META="$(abspath "$META")"
PREAMBLE="$(abspath "$PREAMBLE")"
TEMPLATE="$(abspath "$TEMPLATE")"
CACHE_DIR="$(abspath "$CACHE_DIR")"
DIAGRAMS_DIR="$(abspath "$DIAGRAMS_DIR")"
IMAGES_DIR="$(abspath "$IMAGES_DIR")"

# --- Pre-flight checks -------------------------------------------------------
# (Runs after argument parsing so that --help works without any tool installed.)
for tool in pandoc typst python3; do
    command -v "$tool" >/dev/null 2>&1 \
        || fatal "required tool not found on PATH: $tool"
done
[ -f "$META" ]     || fatal "metadata file not found: $META"
[ -f "$PREAMBLE" ] || fatal "preamble file not found: $PREAMBLE"
[ -f "$TEMPLATE" ] || fatal "template file not found: $TEMPLATE"

echo "pandoc  : $(pandoc --version | head -n1)"
echo "typst   : $(typst --version)"
echo "python3 : $(python3 --version)"
echo

IS_STITCHED=0
if [ -n "$LIST_FILE" ]; then
    [ -f "$LIST_FILE" ] || fatal "list file not found: $LIST_FILE"
    list_dir="$(dirname "$LIST_FILE")"
    STITCHED_FILES=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "$line")"
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue

        if [ -f "$list_dir/$line" ]; then
            STITCHED_FILES+=("$list_dir/$line")
        elif [ -f "$line" ]; then
            STITCHED_FILES+=("$line")
        else
            fatal "file listed in $LIST_FILE not found: $line"
        fi
    done < "$LIST_FILE"

    [ "${#STITCHED_FILES[@]}" -gt 0 ] \
        || fatal "No markdown files found in list file: $LIST_FILE"
    FILES=("${STITCHED_FILES[@]}")
    IS_STITCHED=1
else
    shopt -s nullglob
    if [ "${#FILES[@]}" -eq 0 ]; then
        FILES=(*.md)
    fi
    shopt -u nullglob
fi

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "No markdown files to build."
    exit 0
fi

# --- Clean derived directories -----------------------------------------------
rm -rf PDF
mkdir -p PDF

if [ "$KEEP_RESOLVED" = "1" ]; then
    RESOLVED="$WORK_DIR/resolved"
    rm -rf "$RESOLVED"
    mkdir -p "$RESOLVED"
else
    # No debugging: remove any stale resolved/ and build in a temp directory
    # that is deleted when the script exits.
    rm -rf "$WORK_DIR/resolved"
    mkdir -p "$CACHE_DIR"
    TMP_BUILD="$(mktemp -d "$CACHE_DIR/build.XXXXXX")"
    RESOLVED="$TMP_BUILD/resolved"
    mkdir -p "$RESOLVED"
    trap 'rm -rf "$TMP_BUILD"' EXIT
fi

# --- Mirror any subdirectories (e.g. figures/, assets/) into resolved/ -------
# Note: the glob does not match hidden directories, so .cache/ is never copied.
shopt -s nullglob
for d in */ ; do
    d="${d%/}"
    [ "$d" = "PDF" ] && continue
    [ "$d" = "resolved" ] && continue
    if [ -d "$d" ]; then
        mkdir -p "$RESOLVED/$d"
        cp -r "$d"/. "$RESOLVED/$d/"
    fi
done
shopt -u nullglob

# Initialize non-hidden asset directories inside resolved/ from persistent caches
mkdir -p "$RESOLVED/images" "$RESOLVED/diagrams"
if [ -d "$IMAGES_DIR" ]; then
    cp -r "$IMAGES_DIR"/. "$RESOLVED/images/"
fi
if [ -d "$DIAGRAMS_DIR" ]; then
    cp -r "$DIAGRAMS_DIR"/. "$RESOLVED/diagrams/"
fi

# --- Pandoc invocation (single source of truth) -------------------------------
# NOTE: we deliberately do NOT pipe pandoc's stderr through grep, and we
# deliberately do NOT pass --fail-if-warnings: warnings are printed to
# stderr (loud) but must not abort the build, while real errors still do.
#
# IMPORTANT: --number-sections is deliberately NOT passed. The document
# uses manual "Section N —" labels; auto-numbering would double them up.
#
# IMPORTANT: +gfm_auto_identifiers makes heading anchors GitHub-style
# ("## 3. LaTeX Math" -> #3-latex-math) so that [text](#3-latex-math)
# links resolve; the typst writer then emits matching heading labels.
PANDOC_BASE_ARGS=(
    --pdf-engine=typst
    --metadata-file="$META"
    --template="$TEMPLATE"
    --include-in-header="$PREAMBLE"
    --wrap=none
    -V mainfont="New Computer Modern"
    -V monofont="DejaVu Sans Mono"
    -f markdown+tex_math_single_backslash+tex_math_double_backslash+tex_math_dollars+raw_attribute+smart+pipe_tables+implicit_figures+task_lists+gfm_auto_identifiers
    -t typst
    --lua-filter="$COMPILE_DIR/directives_filter.lua"
    --lua-filter="$COMPILE_DIR/table_filter.lua"
)

# Extra pandoc arguments per build mode (stitched mode adds -M single-toc).
PANDOC_EXTRA_ARGS=()

# Build one PDF.
#   $1: markdown path relative to $RESOLVED (pandoc resolves images wrt cwd)
#   $2: absolute output PDF path
build_pdf() {
    local md_rel="$1" out_pdf="$2"
    mkdir -p "$(dirname "$out_pdf")"
    ( cd "$RESOLVED" && pandoc "$md_rel" "${PANDOC_BASE_ARGS[@]}" "${PANDOC_EXTRA_ARGS[@]}" -o "$out_pdf" )
}

# Preprocess one Markdown file into the resolved tree.
#   $1: source path (relative to cwd or absolute)
#   $2: extra text appended to failure messages (e.g. ", skipping")
# Returns non-zero if any step fails; the caller decides abort vs. skip.
process_file() {
    local file="$1" fail_note="$2"
    local resolved="$RESOLVED/${file}"
    mkdir -p "$(dirname "$resolved")"

    # --- Step 1: preprocess mermaid blocks -----------------------------------
    local mermaid_args=(
        "$COMPILE_DIR/mermaid_processor.py"
        "$file" "$resolved"
        --diagrams-dir "$RESOLVED/diagrams"
        --mmdc "$MMDC"
    )
    if [ "$STRICT_MERMAID" = "1" ]; then
        mermaid_args+=(--strict)
    fi

    if ! python3 "${mermaid_args[@]}"; then
        echo "  -> preprocessing FAILED for $file$fail_note" >&2
        return 1
    fi

    # --- Step 2: download remote images into the local cache -----------------
    if ! python3 "$COMPILE_DIR/image_processor.py" "$resolved" "$resolved" \
            --cache-dir "$RESOLVED/images"; then
        echo "  -> image preprocessing FAILED for $file$fail_note" >&2
        return 1
    fi
    # Steps 3+ (directive expansion, pipe-table conversion) happen inside
    # pandoc via the Lua filters in PANDOC_BASE_ARGS.
}

# --- Convert the selected markdown files -------------------------------------
FAILED=0

if [ "$IS_STITCHED" = "1" ]; then
    out_pdf_base="$(basename "$LIST_FILE")"
    out_pdf_name="${out_pdf_base%.*}.pdf"
    echo "Stitching and converting list: $LIST_FILE -> PDF/$out_pdf_name"

    STITCHED_COMBINED="$RESOLVED/_stitched_combined.md"
    > "$STITCHED_COMBINED"

    # A stitched document with multiple /toc directives would show several
    # tables of contents; -M single-toc makes the directive filter keep only
    # the first. Any preprocessing failure aborts immediately rather than
    # silently producing a PDF with a piece missing.
    PANDOC_EXTRA_ARGS=(-M single-toc=true)
    for file in "${FILES[@]}"; do
        process_file "$file" "" || exit 1
        echo "" >> "$STITCHED_COMBINED"
        echo "" >> "$STITCHED_COMBINED"
        cat "$RESOLVED/${file}" >> "$STITCHED_COMBINED"
    done

    if ! build_pdf "$(basename "$STITCHED_COMBINED")" \
            "$WORK_DIR/PDF/$out_pdf_name"; then
        echo "  -> pandoc FAILED for stitched document" >&2
        exit 1
    fi

    echo "  -> OK: PDF/$out_pdf_name"

else
    for file in "${FILES[@]}"; do
        echo "Converting: $file"

        if ! process_file "$file" ", skipping"; then
            FAILED=$((FAILED + 1))
            continue
        fi

        # --- Step 5: pandoc -> typst -> PDF ----------------------------------
        if ! build_pdf "${file}" "$WORK_DIR/PDF/${file%.md}.pdf"; then
            echo "  -> pandoc FAILED for $file, skipping" >&2
            FAILED=$((FAILED + 1))
            continue
        fi

        echo "  -> OK: PDF/${file%.md}.pdf"
    done
fi

# Sync back any newly downloaded or rendered assets to persistent caches
mkdir -p "$IMAGES_DIR" "$DIAGRAMS_DIR"
cp -r "$RESOLVED/images"/. "$IMAGES_DIR/" 2>/dev/null || true
cp -r "$RESOLVED/diagrams"/. "$DIAGRAMS_DIR/" 2>/dev/null || true

echo
echo "Done. Output in: $WORK_DIR/PDF"
if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED of ${#FILES[@]} file(s) FAILED to build." >&2
    exit 1
fi
