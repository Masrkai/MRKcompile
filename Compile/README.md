# Compile — Markdown → PDF build pipeline

This directory contains the toolchain that turns plain Markdown documents into
typeset PDFs using **pandoc + Typst**, with automatic rendering of **Mermaid
diagrams** and conversion of **Markdown tables** into native Typst tables.

```
source .md ──► preprocess_mermaid.py ──► preprocess_images.py ──► preprocess_tables.py ──► pandoc ──► typst ──► PDF
              (```mermaid → image)      (remote img → local)     (| tables | → #table)     (typst writer)
```

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| `pandoc` | Markdown → Typst conversion | package manager or <https://pandoc.org> |
| `typst` | PDF engine (invoked by pandoc) | package manager or <https://typst.app> |
| `python3` | runs the preprocessors | usually preinstalled |
| `mmdc` | renders Mermaid diagrams | `npm install -g @mermaid-js/mermaid-cli` |

`mmdc` is only needed if your documents contain ` ```mermaid ` blocks. Node.js
comes with it via npm.

## Usage

Run the build script **from the directory that contains your `.md` files**
(the script may be invoked by its path from anywhere):

```bash
/path/to/Compile/run_typst_final.sh                # build every top-level *.md
/path/to/Compile/run_typst_final.sh a.md b.md      # build only the named files
```

For each selected file it will:

1. Copy the source into `resolved/` so relative image paths resolve.
2. Run `preprocess_mermaid.py`, replacing each ` ```mermaid ` block with an
   image reference to a PDF rendered by `mmdc` (cached by content hash in
   `.cache/diagrams/`).
3. Run `preprocess_images.py`, downloading remote `http(s)` images into
   `.cache/images/` and rewriting the references (Typst cannot fetch URLs).
4. Run `preprocess_tables.py` on `*_resolved.md` files, converting pipe tables
   into native Typst `#table(...)` blocks.
5. Run `pandoc` with the Typst PDF engine, producing `PDF/<name>.pdf`.

The script exits non-zero if any selected file failed to build.

### Intermediates and debugging

By default all intermediates live in a temporary directory under `.cache/`
that is deleted when the build finishes; a stale `./resolved/` is removed as
well. Only the persistent caches (`.cache/diagrams/`, `.cache/images/`) and
the `PDF/` output survive a run.

To inspect the preprocessed Markdown (and the files pandoc actually sees),
build with debugging enabled — this creates `./resolved/` in the working
directory and keeps it:

```bash
KEEP_RESOLVED=1 /path/to/Compile/run_typst_final.sh
```

### Diagram captions

Add a caption to a Mermaid diagram with a comment as the first line of the
fence — it becomes the figure caption in the PDF:

~~~
```mermaid
%% caption: Figure 1: System architecture.
flowchart LR
    A --> B
```
~~~

If a diagram fails to render, the original fence is kept (it appears as a code
block in the PDF) and a warning is printed. Set `STRICT_MERMAID=1` to abort the
build instead.

### Remote images

Typst cannot fetch URLs, so `![alt](https://...)` references are downloaded by
`preprocess_images.py` into `.cache/images/` (cached by URL hash) and rewritten
to relative local paths. A failed download leaves the remote reference in
place and prints a warning; the build then fails loudly at the typst stage.

### Anchor links

Heading anchors follow the GitHub convention (`## 3. LaTeX Math` →
`#3-latex-math`), enabled via pandoc's `gfm_auto_identifiers`, so
`[text](#3-latex-math)` links resolve in the PDF.

### Warnings vs errors

Pandoc and typst warnings are printed to stderr but do not abort the build;
real errors do. A warning usually means degraded output (e.g. a LaTeX command
the converter does not know), not a broken pipeline.

### Environment overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `META` | `Compile/meta.yaml` | pandoc metadata file |
| `PREAMBLE` | `Compile/preamble.typ` | Typst preamble injected via `--include-in-header` |
| `CACHE_DIR` | `./.cache` | persistent cache root (diagrams, images, temp builds) |
| `DIAGRAMS_DIR` | `$CACHE_DIR/diagrams` | Mermaid render cache |
| `IMAGES_DIR` | `$CACHE_DIR/images` | remote image download cache |
| `MMDC` | `mmdc` on PATH | path to the Mermaid CLI |
| `STRICT_MERMAID` | `0` | `1` = fail the build on diagram errors |
| `KEEP_RESOLVED` | `0` | `1` = build into `./resolved` and keep it for debugging |

## Files

| File | Role |
|------|------|
| `run_typst_final.sh` | orchestrator: file selection, pre-flight checks, preprocessing, pandoc call |
| `preprocess_mermaid.py` | ` ```mermaid ` fences → rendered PDF images (with captions) |
| `preprocess_images.py` | remote `http(s)` images → local cached copies |
| `preprocess_tables.py` | pipe tables → native Typst `#table(...)` blocks |
| `table-to-typst.lua` | alternative pandoc Lua filter doing the same table conversion inside pandoc (not wired into the shell script by default) |
| `preamble.typ` | page geometry, fonts, heading/table/figure/code styling, matrix delimiter workaround |
| `meta.yaml` | document metadata (TOC depth, etc.) |

## Conventions you must respect when editing sources

- **Do not enable `number-sections`** (neither in `meta.yaml` nor as a pandoc
  flag). Headings carry manual "Section N —" labels; auto-numbering would
  double them up.
- **Page geometry, fonts and spacing live in `preamble.typ`**, not in
  `meta.yaml`. The Typst writer ignores a nested `margin:` metadata map.
- **Math** is parsed with `tex_math_dollars` plus the single/double backslash
  extensions; write LaTeX-style math (`$\mathbf{x}$` etc.). The table
  preprocessor translates a few common commands (`\mathbf`, `\text`,
  `\approx`, `\pm`) inside table cells.
- **Mermaid caches are content-hashed.** If you change the `mmdc` invocation
  in `preprocess_mermaid.py`, bump `CACHE_VERSION` so stale renders are
  invalidated.
- **Tables** must be standard pipe tables with a `---` separator row to be
  converted; anything else is left untouched.
- **Matrix delimiters**: pandoc's math converter emits `mat(delim: "||", ...)`
  for `\begin{vmatrix}`, which Typst rejects; `preamble.typ` wraps `mat` to
  map `"||"` to the single-character `‖`. If you upgrade pandoc/typst and
  this is fixed upstream, remove the workaround from `preamble.typ`.

## Testing

`../testfiles/` contains sample documents (`01-basic.md`, `02-intermediate.md`,
`03-stress-test.md`). Copy them next to the script (or run the script from
that directory) to verify the pipeline end-to-end:

```bash
cd ../testfiles && ../Compile/run_typst_final.sh
```
