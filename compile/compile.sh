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
#  Path handling: for stitched builds (-l) the LIST FILE'S DIRECTORY is the
#  project root — list entries resolve against it, so the script may be
#  invoked from any cwd. Relative asset paths in the documents resolve
#  against the document's own directory first, then the project root (see
#  asset_path_processor.sh). Stitched sources are staged flat into resolved/
#  by basename; duplicate basenames are a hard error. Normal builds resolve
#  against the cwd.
#
#  Pipeline per file (see process_file):
#    0. Run asset_path_processor.sh to rewrite relative asset paths so they
#       resolve from resolved/ (document-relative first, project root second).
#    1. Run mermaid_processor.sh to replace ```mermaid blocks with image refs
#       (in place on the resolved copy).
#    2. Run image_processor.sh to download remote images into the local cache.
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
#    ALLOW_HTTP     set to 1 to let image_processor.sh fetch plaintext http://
#                   images (default: 0, HTTPS-only)
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
                  (entries resolve against the list file's directory; asset
                  paths against the document's directory, then the list
                  file's directory; '#' comments)
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
  ALLOW_HTTP=1          allow plaintext http:// image downloads (default: 0,
                        HTTPS-only; see image_processor.sh)

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
for tool in pandoc typst curl; do
    command -v "$tool" >/dev/null 2>&1 \
        || fatal "required tool not found on PATH: $tool"
done
[ -f "$META" ]     || fatal "metadata file not found: $META"
[ -f "$PREAMBLE" ] || fatal "preamble file not found: $PREAMBLE"
[ -f "$TEMPLATE" ] || fatal "template file not found: $TEMPLATE"

echo "pandoc  : $(pandoc --version | head -n1)"
echo "typst   : $(typst --version)"
echo "curl    : $(curl --version | head -n1)"
echo

IS_STITCHED=0
PROJECT_ROOT="$WORK_DIR"
if [ -n "$LIST_FILE" ]; then
    LIST_FILE="$(abspath "$LIST_FILE")"
    [ -f "$LIST_FILE" ] || fatal "list file not found: $LIST_FILE"
    list_dir="$(dirname "$LIST_FILE")"

    # The stitched build's project root is the list file's directory: list
    # entries AND relative asset paths in the documents (images, SVGs, ...)
    # resolve against it, so the script may be invoked from any cwd.
    PROJECT_ROOT="$list_dir"

    # Stitched sources are staged flat into resolved/ (by basename) so that
    # every relative asset path — author-written or processor-written —
    # resolves from the same root. Duplicate basenames would be
    # indistinguishable in the combined document, so they are a hard error.
    STITCHED_SOURCES=()
    STITCHED_NAMES=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "$line")"
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue

        [ -f "$list_dir/$line" ] \
            || fatal "file listed in $LIST_FILE not found: $line (entries resolve against $list_dir)"

        base="$(basename "$line")"
        [ "$base" = "_stitched_combined.md" ] \
            && fatal "reserved name in $LIST_FILE: $base"
        for prev in "${STITCHED_NAMES[@]:-}"; do
            [ -n "$prev" ] || continue
            [ "$prev" = "$base" ] \
                && fatal "duplicate basename in $LIST_FILE: $base (stitched sources are staged flat; rename one of the files)"
        done

        STITCHED_SOURCES+=("$list_dir/$line")
        STITCHED_NAMES+=("$base")
    done < "$LIST_FILE"

    [ "${#STITCHED_NAMES[@]}" -gt 0 ] \
        || fatal "No markdown files found in list file: $LIST_FILE"
    # FILES is kept in sync for the failure-count reporting at the end.
    FILES=("${STITCHED_NAMES[@]}")
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

# --- Mirror the project root's asset tree into resolved/ ---------------------
# Subdirectories of the project root (e.g. figures/, assets/) are copied
# wholesale so that relative asset paths resolve from resolved/, which is
# where pandoc runs. For normal builds the project root is the cwd; for
# stitched (-l) builds it is the list file's directory.
# Note: the glob does not match hidden directories, so .cache/ is never copied.
shopt -s nullglob
for d in "$PROJECT_ROOT"/*/ ; do
    d="${d%/}"
    base="$(basename "$d")"
    [ "$base" = "PDF" ] && continue
    [ "$base" = "resolved" ] && continue
    if [ -d "$d" ]; then
        mkdir -p "$RESOLVED/$base"
        cp -r "$d"/. "$RESOLVED/$base/"
    fi
done
shopt -u nullglob

# --- Loose asset files (e.g. logo.svg next to the documents) ------------------
# Non-hidden, non-directory, non-markdown files in the project root are
# copied as well so that relative references to sibling assets resolve.
# (The list file itself is skipped in stitched builds.)
shopt -s nullglob
for f in "$PROJECT_ROOT"/* ; do
    [ -f "$f" ] || continue
    [ "$f" = "$LIST_FILE" ] && continue
    case "$f" in
        *.md) continue ;;
    esac
    cp "$f" "$RESOLVED/"
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
#   $2: staging path for the resolved copy, relative to $RESOLVED
#   $3: extra text appended to failure messages (e.g. ", skipping")
# Returns non-zero if any step fails; the caller decides abort vs. skip.
process_file() {
    local src="$1" staged="$2" fail_note="$3"
    local resolved="$RESOLVED/${staged}"
    mkdir -p "$(dirname "$resolved")"

    # --- Step 0: resolve relative asset paths --------------------------------
    # Rewrites relative image targets so they resolve from the root of
    # resolved/ (where pandoc runs): relative to the document's own
    # directory first, then to the project root. See asset_path_processor.sh.
    if ! "$COMPILE_DIR/asset_path_processor.sh" "$src" "$resolved" \
            --project-root "$PROJECT_ROOT"; then
        echo "  -> asset path resolution FAILED for $staged$fail_note" >&2
        return 1
    fi

    # --- Step 1: preprocess mermaid blocks (in place on the resolved copy) ---
    local mermaid_args=(
        "$COMPILE_DIR/mermaid_processor.sh"
        "$resolved" "$resolved"
        --diagrams-dir "$RESOLVED/diagrams"
        --mmdc "$MMDC"
    )
    if [ "$STRICT_MERMAID" = "1" ]; then
        mermaid_args+=(--strict)
    fi

    if ! "${mermaid_args[@]}"; then
        echo "  -> preprocessing FAILED for $staged$fail_note" >&2
        return 1
    fi

    # --- Step 2: download remote images into the local cache -----------------
    if ! "$COMPILE_DIR/image_processor.sh" "$resolved" "$resolved" \
            --cache-dir "$RESOLVED/images"; then
        echo "  -> image preprocessing FAILED for $staged$fail_note" >&2
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
    for i in "${!STITCHED_SOURCES[@]}"; do
        src="${STITCHED_SOURCES[$i]}"
        staged="${STITCHED_NAMES[$i]}"
        echo "  + ${src#"$PROJECT_ROOT/"}"
        process_file "$src" "$staged" "" || exit 1
        echo "" >> "$STITCHED_COMBINED"
        echo "" >> "$STITCHED_COMBINED"
        cat "$RESOLVED/${staged}" >> "$STITCHED_COMBINED"
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

        if ! process_file "$file" "$file" ", skipping"; then
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
