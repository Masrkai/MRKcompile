# Compile — Markdown → PDF build pipeline

This directory contains the toolchain that turns plain Markdown documents into
typeset PDFs using **pandoc + Typst**, with automatic rendering of **Mermaid
diagrams** and conversion of **Markdown tables** into native Typst tables.

```
source .md ──► asset_path_processor.sh ──► mermaid_processor.sh ──► image_processor.sh ──►  pandoc (Lua filters)  ──► typst ──► PDF
                (relative asset →            (```mermaid → image)      (remote img → local)     ↑                        (typst writer)
                 resolved-root path)                                                          inside pandoc:
                                                                                              directives_filter.lua (/toc, /breakpage → typst)
                                                                                              table_filter.lua (| tables | → #table)
```

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| `pandoc` | Markdown → Typst conversion | package manager or <https://pandoc.org> |
| `typst` | PDF engine (invoked by pandoc) | package manager or <https://typst.app> |
| `curl` | downloads remote images (used by `image_processor.sh`) | usually preinstalled |
| `mmdc` | renders Mermaid diagrams | `npm install -g @mermaid-js/mermaid-cli` |

`mmdc` is only needed if your documents contain ` ```mermaid ` blocks. Node.js
comes with it via npm.

## Usage

Run the build script **from the directory that contains your `.md` files**
(the script may be invoked by its path from anywhere — with `-l` this is not
required at all, see below):

```bash
/path/to/Compile/compile.sh                # build every top-level *.md
/path/to/Compile/compile.sh a.md b.md      # build only the named files
/path/to/Compile/compile.sh -l list.txt    # stitch and build files listed in list.txt
/path/to/Compile/compile.sh -h             # show help (also: --help)
```

File arguments in normal mode are relative to the working directory;
absolute paths are not supported. Relative asset paths inside the documents
are resolved per the rules in *Relative asset paths* below.

For each selected file it will:

1. Copy the source into `resolved/`, rewriting relative asset paths so they
   resolve from the `resolved/` root (see *Relative asset paths* below).
2. Run `mermaid_processor.sh`, replacing each ` ```mermaid ` block with an
   image reference to a PDF rendered by `mmdc` (cached by content hash in
   `.cache/diagrams/`).
3. Run `image_processor.sh`, downloading remote `http(s)` images into
   `.cache/images/` and rewriting the references (Typst cannot fetch URLs).
4. Run `pandoc` with the Typst PDF engine, producing `PDF/<name>.pdf`. Two
   pandoc Lua filters run inside that invocation, in order:
   `directives_filter.lua` expands `/toc`, `/breakpage`, `/newpage` and
   `/pagebreak` into raw Typst blocks (stitched builds pass
   `-M single-toc=true`), then `table_filter.lua` converts pipe tables into
   native Typst `#table(...)` blocks.

### Relative asset paths

pandoc/typst resolve every relative path against the working directory of
the build — the root of the `resolved/` staging tree — not against the
document's own location. `asset_path_processor.sh` therefore rewrites
relative `![...](path)` image targets before pandoc runs:

1. If the target exists relative to the **document's own directory**, it is
   rewritten to that location (so `docs/pic.svg` referenced from
   `docs/chapter.md` becomes a path that resolves from the `resolved/`
   root).
2. Otherwise, if the target already exists relative to the **project root**
   (the working directory for normal builds, the list file's directory for
   stitched builds), it is left unchanged.
3. Otherwise the reference is left untouched and a warning is printed; the
   build then fails loudly at the typst stage ("file not found").

When both candidates exist, the document-relative one wins. Only
`![...](...)` image syntax is handled: `http(s)://` targets belong to
`image_processor.sh`, and `#anchors`, absolute paths and targets containing
whitespace or parentheses are left untouched. Code fences are skipped so
example content is not altered (indented code blocks are not tracked); raw
HTML `<img>` is out of scope.

The script exits non-zero if any selected file failed to build.

### Stitched builds (`-l`)

For a stitched build the **list file's directory is the project root**:

- List entries resolve against the directory containing the list file (a
  missing entry is a hard error; there is no fallback to the working
  directory). The script may therefore be invoked from any cwd.
- The asset tree (subdirectories and loose asset files such as `logo.svg`)
  is mirrored from the list file's directory into `resolved/`, and relative
  asset paths in the documents are resolved by `asset_path_processor.sh`
  (document-relative first, then project root; see *Relative asset paths*
  above).
- Sources are staged flat into `resolved/` by basename, so two entries
  sharing a basename (e.g. `a/ch1.md` and `b/ch1.md`) abort the build; the
  combined output is written to `PDF/<list-file-name>.pdf` in the working
  directory.

Stitched builds pass `-M single-toc=true` to pandoc so that
`directives_filter.lua` expands only the first `/toc` globally; the filter
runs on per-file and on combined documents alike.

### Intermediates and debugging

By default all intermediates live in a temporary directory under `.cache/`
that is deleted when the build finishes; a stale `./resolved/` is removed as
well. Only the persistent caches (`.cache/diagrams/`, `.cache/images/`) and
the `PDF/` output survive a run.

To inspect the preprocessed Markdown (and the files pandoc actually sees),
build with debugging enabled — this creates `./resolved/` in the working
directory and keeps it:

```bash
KEEP_RESOLVED=1 /path/to/Compile/compile.sh
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
`image_processor.sh` into `.cache/images/` (cached by URL hash) and rewritten
to relative local paths. A failed download leaves the remote reference in
place and prints a warning; the build then fails loudly at the typst stage.

### Anchor links

Heading anchors follow the GitHub convention (`## 3. LaTeX Math` →
`#3-latex-math`), enabled via pandoc's `gfm_auto_identifiers`, so
`[text](#3-latex-math)` links resolve in the PDF.

### Table of Contents & Page Breaks

- **Table of Contents (TOC):** Opt-in per document by adding `toc: true` to the document's YAML frontmatter, or by placing `/toc` in the body. When stitching multiple files with `-l`, `/toc` can be used at most once globally (subsequent occurrences are dropped; the script passes `-M single-toc=true` and `directives_filter.lua` handles it).
- **Page Breaks:** Insert page breaks explicitly using `/breakpage`, `/newpage`, or `/pagebreak`.
- **Matching:** Directives expand by exact occurrence anywhere in the text — including inside code fences. That is intentional and preserved from the pipeline's history; do not rely on a bare `/toc` inside an example being left alone.

### Warnings vs errors

Pandoc and typst warnings are printed to stderr but do not abort the build;
real errors do. A warning usually means degraded output (e.g. a LaTeX command
the converter does not know), not a broken pipeline.

### Environment overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `META` | `compile/metadata.yaml` | pandoc metadata file |
| `PREAMBLE` | `compile/preamble.typ` | Typst preamble injected via `--include-in-header` |
| `CACHE_DIR` | `./.cache` | persistent cache root (diagrams, images, temp builds) |
| `DIAGRAMS_DIR` | `$CACHE_DIR/diagrams` | Mermaid render cache |
| `IMAGES_DIR` | `$CACHE_DIR/images` | remote image download cache |
| `MMDC` | `mmdc` on PATH | path to the Mermaid CLI |
| `STRICT_MERMAID` | `0` | `1` = fail the build on diagram errors |
| `KEEP_RESOLVED` | `0` | `1` = build into `./resolved` and keep it for debugging |

## Files

| File | Role |
|------|------|
| `compile.sh` | orchestrator: file selection, pre-flight checks, preprocessing, pandoc call |
| `asset_path_processor.sh` | relative `![...](path)` targets → paths that resolve from the `resolved/` root |
| `mermaid_processor.sh` | ` ```mermaid ` fences → rendered PDF images (with captions) |
| `image_processor.sh` | remote `http(s)` images → local cached copies |
| `directives_filter.lua` | pandoc Lua filter: `/toc`, `/breakpage`, `/newpage`, `/pagebreak` → raw Typst blocks (`-M single-toc=true` for stitched builds) |
| `table_filter.lua` | pandoc Lua filter: pipe tables → native Typst `#table(...)` blocks |
| `preamble.typ` | page geometry, fonts, heading/table/figure/code styling, matrix delimiter workaround |
| `metadata.yaml` | document metadata (TOC depth, etc.) |

## Conventions you must respect when editing sources

- **Do not enable `number-sections`** (neither in `metadata.yaml` nor as a pandoc
  flag). Headings carry manual "Section N —" labels; auto-numbering would
  double them up.
- **Page geometry, fonts and spacing live in `preamble.typ`**, not in
  `metadata.yaml`. The Typst writer ignores a nested `margin:` metadata map.
- **Math** is parsed with `tex_math_dollars` plus the single/double backslash
  extensions; write LaTeX-style math (`$\mathbf{x}$` etc.). Inside table cells,
  pandoc converts LaTeX math to Typst natively.
- **Mermaid caches are content-hashed.** If you change the `mmdc` invocation
  in `mermaid_processor.sh`, bump `CACHE_VERSION` so stale renders are
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
cd ../testfiles && ../compile/compile.sh
```
