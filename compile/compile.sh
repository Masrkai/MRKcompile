#!/usr/bin/env bash
# =============================================================================
#  Build Markdown files into PDFs using pandoc + typst.
#
#  Usage:
#    compile.sh                         build every top-level *.md in cwd
#    compile.sh a.md [b.md ...]         build only the named files
#    compile.sh -l list.txt             stitch and build files listed in list.txt
#
#  Pipeline per file:
#    1. Copy the source .md into resolved/ (so relative image paths work).
#    2. Run mermaid_processor.py to replace ```mermaid blocks with image refs.
#    3. Run image_processor.py to download remote images into the local cache.
#    4. Run table_processor.py on *_resolved.md sources (pipe tables -> Typst).
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

META="${META:-$COMPILE_DIR/metadata.yaml}"
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

# --- File selection & options ------------------------------------------------
LIST_FILE=""
FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l)
            if [ -z "${2:-}" ]; then
                echo "ERROR: -l requires an argument (list file)" >&2
                exit 1
            fi
            LIST_FILE="$2"
            shift 2
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            exit 1
            ;;
        *)
            FILES+=("$1")
            shift
            ;;
    esac
done

IS_STITCHED=0
if [ -n "$LIST_FILE" ]; then
    if [ ! -f "$LIST_FILE" ]; then
        echo "ERROR: list file not found: $LIST_FILE" >&2
        exit 1
    fi
    list_dir="$(dirname "$LIST_FILE")"
    STITCHED_FILES=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(echo "$line" | xargs)"
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue

        resolved_path=""
        if [ -f "$list_dir/$line" ]; then
            resolved_path="$list_dir/$line"
        elif [ -f "$line" ]; then
            resolved_path="$line"
        else
            echo "ERROR: file listed in $LIST_FILE not found: $line" >&2
            exit 1
        fi
        STITCHED_FILES+=("$resolved_path")
    done < "$LIST_FILE"

    if [ "${#STITCHED_FILES[@]}" -eq 0 ]; then
        echo "No markdown files found in list file: $LIST_FILE" >&2
        exit 1
    fi
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
    cp -r "$IMAGES_DIR"/. "$RESOLVED/images/" 2>/dev/null || true
fi
if [ -d "$DIAGRAMS_DIR" ]; then
    cp -r "$DIAGRAMS_DIR"/. "$RESOLVED/diagrams/" 2>/dev/null || true
fi

# --- Convert the selected markdown files -------------------------------------
FAILED=0

if [ "$IS_STITCHED" = "1" ]; then
    out_pdf_base="$(basename "$LIST_FILE")"
    out_pdf_name="${out_pdf_base%.*}.pdf"
    echo "Stitching and converting list: $LIST_FILE -> PDF/$out_pdf_name"

    STITCHED_COMBINED="$RESOLVED/_stitched_combined.md"
    > "$STITCHED_COMBINED"

    for file in "${FILES[@]}"; do
        resolved="$RESOLVED/${file}"
        mkdir -p "$(dirname "$resolved")"

        mermaid_args=(
            "$COMPILE_DIR/mermaid_processor.py"
            "$file" "$resolved"
            --diagrams-dir "$RESOLVED/diagrams"
            --mmdc "$MMDC"
        )
        if [ "$STRICT_MERMAID" = "1" ]; then
            mermaid_args+=(--strict)
        fi

        if ! python3 "${mermaid_args[@]}"; then
            echo "  -> preprocessing FAILED for $file" >&2
            exit 1
        fi

        if ! python3 "$COMPILE_DIR/image_processor.py" "$resolved" "$resolved" \
                --cache-dir "$RESOLVED/images"; then
            echo "  -> image preprocessing FAILED for $file" >&2
            exit 1
        fi

        echo "" >> "$STITCHED_COMBINED"
        echo "" >> "$STITCHED_COMBINED"
        cat "$resolved" >> "$STITCHED_COMBINED"
    done

    # Handle global directives: global /toc deduplication, /breakpage, /pagebreak, /newpage
    python3 -c '
path = "'"$STITCHED_COMBINED"'"
text = open(path, "r", encoding="utf-8").read()

parts = text.split("/toc")
if len(parts) > 1:
    text = parts[0] + "```{=typst}\n#outline()\n```" + "".join(parts[1:])

text = text.replace("/breakpage", "```{=typst}\n#pagebreak()\n```")
text = text.replace("/pagebreak", "```{=typst}\n#pagebreak()\n```")
text = text.replace("/newpage", "```{=typst}\n#pagebreak()\n```")
open(path, "w", encoding="utf-8").write(text)
'

    if ! (
        cd "$RESOLVED" && \
        out_pdf="$WORK_DIR/PDF/$out_pdf_name" && \
        mkdir -p "$(dirname "$out_pdf")" && \
        pandoc "$(basename "$STITCHED_COMBINED")" \
            --pdf-engine=typst \
            --metadata-file="$META" \
            --include-in-header="$PREAMBLE" \
            --wrap=none \
            -V mainfont="New Computer Modern" \
            -V monofont="DejaVu Sans Mono" \
            -f markdown+tex_math_single_backslash+tex_math_double_backslash+tex_math_dollars+raw_attribute+smart+pipe_tables+implicit_figures+gfm_auto_identifiers \
            -t typst \
            -o "$out_pdf"
    ); then
        echo "  -> pandoc FAILED for stitched document" >&2
        exit 1
    fi

    echo "  -> OK: PDF/$out_pdf_name"

else
    for file in "${FILES[@]}"; do
        echo "Converting: $file"

        resolved="$RESOLVED/${file}"
        mkdir -p "$(dirname "$resolved")"

        # --- Step 1: preprocess mermaid blocks -----------------------------------
        mermaid_args=(
            "$COMPILE_DIR/mermaid_processor.py"
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
        if ! python3 "$COMPILE_DIR/image_processor.py" "$resolved" "$resolved" \
                --cache-dir "$RESOLVED/images"; then
            echo "  -> image preprocessing FAILED for $file, skipping" >&2
            FAILED=$((FAILED + 1))
            continue
        fi

        # --- Step 1c: handle custom directives (/toc, /breakpage, /newpage, /pagebreak) ------
        python3 -c '
path = "'"$resolved"'"
text = open(path, "r", encoding="utf-8").read()
text = text.replace("/toc", "```{=typst}\n#outline()\n```")
text = text.replace("/breakpage", "```{=typst}\n#pagebreak()\n```")
text = text.replace("/newpage", "```{=typst}\n#pagebreak()\n```")
text = text.replace("/pagebreak", "```{=typst}\n#pagebreak()\n```")
open(path, "w", encoding="utf-8").write(text)
'

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
                -o "$out_pdf"
        ); then
            echo "  -> pandoc FAILED for $file" >&2
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
