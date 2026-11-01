#!/usr/bin/env bash
# =============================================================================
#  Build Markdown files into PDFs using pandoc + typst.
#
#  Usage:
#    run_typst_final.sh                 build every top-level *.md in cwd
#    run_typst_final.sh a.md [b.md ...] build only the named files
#
#  Pipeline per file:
#    1. Copy the source .md into resolved/ (so relative image paths work).
#    2. Run preprocess_mermaid.py to replace ```mermaid blocks with image refs.
#    3. Run preprocess_images.py to download remote images into the local cache.
#    4. Run preprocess_tables.py on *_resolved.md sources (pipe tables -> Typst).
#    5. Run pandoc with the typst PDF engine -> PDF/<name>.pdf
#
#  Intermediates: by default everything is built inside a temporary directory
#  under .cache/ that is deleted when the script exits. Set KEEP_RESOLVED=1
#  to build into ./resolved and keep it for debugging.
#
#  Environment overrides:
#    META           path to metadata yaml    (default: <Compile>/meta.yaml)
#    PREAMBLE       path to typst preamble   (default: <Compile>/preamble.typ)
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

META="${META:-$COMPILE_DIR/meta.yaml}"
PREAMBLE="${PREAMBLE:-$COMPILE_DIR/preamble.typ}"
CACHE_DIR="${CACHE_DIR:-$WORK_DIR/.cache}"
DIAGRAMS_DIR="${DIAGRAMS_DIR:-$CACHE_DIR/diagrams}"
IMAGES_DIR="${IMAGES_DIR:-$CACHE_DIR/images}"
MMDC="${MMDC:-mmdc}"
STRICT_MERMAID="${STRICT_MERMAID:-0}"
KEEP_RESOLVED="${KEEP_RESOLVED:-0}"

# --- Pre-flight checks -------------------------------------------------------
for tool in pandoc typst python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool not found on PATH: $tool" >&2
        exit 1
    fi
done
if [ ! -f "$META" ]; then
    echo "ERROR: metadata file not found: $META" >&2
    exit 1
fi
if [ ! -f "$PREAMBLE" ]; then
    echo "ERROR: preamble file not found: $PREAMBLE" >&2
    exit 1
fi

echo "pandoc  : $(pandoc --version | head -n1)"
echo "typst   : $(typst --version)"
echo "python3 : $(python3 --version)"
echo

# --- File selection ----------------------------------------------------------
shopt -s nullglob
if [ $# -gt 0 ]; then
    FILES=("$@")
    for f in "${FILES[@]}"; do
        if [ ! -f "$f" ]; then
            echo "ERROR: file not found: $f" >&2
            exit 1
        fi
    done
else
    FILES=(*.md)
fi
shopt -u nullglob

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
    cp -r "$IMAGES_DIR"/. "$RESOLVED/images/" 2>/dev/null || true
fi
if [ -d "$DIAGRAMS_DIR" ]; then
    cp -r "$DIAGRAMS_DIR"/. "$RESOLVED/diagrams/" 2>/dev/null || true
fi

# --- Convert the selected markdown files -------------------------------------
FAILED=0
for file in "${FILES[@]}"; do
    echo "Converting: $file"

    resolved="$RESOLVED/${file}"

    # --- Step 1: preprocess mermaid blocks -----------------------------------
    mermaid_args=(
        "$COMPILE_DIR/preprocess_mermaid.py"
        "$file" "$resolved"
        --diagrams-dir "$RESOLVED/diagrams"
        --mmdc "$MMDC"
    )
    if [ "$STRICT_MERMAID" = "1" ]; then
        mermaid_args+=(--strict)
    fi

    if ! python3 "${mermaid_args[@]}"; then
        echo "  -> preprocessing FAILED for $file, skipping" >&2
        FAILED=$((FAILED + 1))
        continue
    fi

    # --- Step 1b: download remote images into the local cache ----------------
    if ! python3 "$COMPILE_DIR/preprocess_images.py" "$resolved" "$resolved" \
            --cache-dir "$RESOLVED/images"; then
        echo "  -> image preprocessing FAILED for $file, skipping" >&2
        FAILED=$((FAILED + 1))
        continue
    fi

    # --- Step 2: pandoc -> typst -> PDF --------------------------------------
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
    if ! (
        cd "$RESOLVED" && \
        out_pdf="$WORK_DIR/PDF/${file%.md}.pdf" && \
        mkdir -p "$(dirname "$out_pdf")" && \
        pandoc "${file}" \
            --pdf-engine=typst \
            --metadata-file="$META" \
            --include-in-header="$PREAMBLE" \
            --wrap=none \
            -V mainfont="New Computer Modern" \
            -V monofont="DejaVu Sans Mono" \
            -f markdown+tex_math_single_backslash+tex_math_double_backslash+tex_math_dollars+raw_attribute+smart+pipe_tables+implicit_figures+gfm_auto_identifiers \
            -t typst \
            -o "$out_pdf" \
            --toc --toc-depth=3
    ); then
        echo "  -> pandoc FAILED for $file" >&2
        FAILED=$((FAILED + 1))
        continue
    fi

    echo "  -> OK: PDF/${file%.md}.pdf"
done

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
