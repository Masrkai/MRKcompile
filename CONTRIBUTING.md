# Maintainer & Contributor Guide

This document explains how to navigate, use, and extend the MRKcompile
project, and the principles behind its design. **Read this before changing
anything.**

## What this project is

MRKcompile is a document compilation pipeline: it takes Markdown sources and
produces typeset PDFs via `pandoc` + `typst`. The `compile/` directory holds
the entire toolchain; `testfiles/` holds sample documents for verification.

## How to navigate the project

```
MRKcompile/
├── compile/                  ← the toolchain (see compile/README.md)
│   ├── compile.sh            ← entry point; run this to build
│   ├── mermaid_processor.py  ← mermaid fences → rendered PDF figures
│   ├── image_processor.py    ← remote http(s) images → local cached copies
│   ├── directives_filter.lua ← pandoc filter: /toc, /breakpage directives → Typst blocks
│   ├── table_filter.lua      ← pandoc filter: pipe tables → native Typst tables
│   ├── preamble.typ          ← all page/typography styling
│   ├── metadata.yaml         ← document metadata (TOC, etc.)
│   └── README.md             ← build instructions and file map
├── testfiles/                ← sample .md documents for end-to-end tests
├── README.md                 ← project overview and architecture diagram
├── CONTRIBUTING.md           ← maintainer & contributor guide
└── AGENTS.md                 ← instructions for AI agents working here
```

During a build the working directory also gains `PDF/` (output) and a hidden
`.cache/` (persistent mermaid/image caches plus temporary build dirs). The
`resolved/` directory with preprocessed Markdown only exists when you build
with `KEEP_RESOLVED=1` for debugging.

Start points by task:

- **"How do I build a PDF?"** → root `README.md` or `compile/README.md`, Usage section.
- **"My diagram/table looks wrong"** → `compile/README.md`, Conventions
  section, then the relevant preprocessor's docstring or filter's header
  comment.
- **"Styling is off"** → `compile/preamble.typ` owns all visual settings.
- **"Something broke"** → run the script from `testfiles/` to isolate whether
  the problem is in your document or in the pipeline.

## How to use the project

1. Write your document as plain Markdown in a working directory.
2. Run `compile/compile.sh` from that directory — with no arguments it
   builds every top-level `*.md`; pass file names to build only those.
3. Collect output from `PDF/`. Intermediates are hidden in `.cache/` and
   cleaned up automatically; build with `KEEP_RESOLVED=1` if you need to
   inspect the preprocessed Markdown. Never edit intermediates — they are
   regenerated on every run.

To test changes to the pipeline itself, run it against `testfiles/`:

```bash
cd testfiles && ../compile/compile.sh
```

## Principles behind the project

These are the reasons the code looks the way it does. Keep them intact when
extending.

1. **Sources stay pristine.** Preprocessors never modify the input `.md`.
   All derived files go to `resolved/` and `PDF/`, both wiped on each build.
   A document must remain readable and portable without this pipeline.

2. **Failures must be loud, never silent.** The script uses `set -euo
   pipefail`, checks for tools up front, and exits non-zero if any selected
   file fails to build. Warnings from pandoc/typst are printed to stderr but
   do not abort the build — a warning means degraded output, an error means a
   broken build. A failed mermaid render is *visible* in the output (kept as
   a code block) rather than quietly dropped. Do not add error suppression,
   stderr filtering, or fallbacks that hide problems.

3. **One source of truth per concern.**
   - Styling → `preamble.typ` only.
   - Metadata → `metadata.yaml` only.
   - Section numbering → manual "Section N —" labels in the documents;
     auto-numbering is deliberately off to avoid double numbering.
   If two mechanisms can express the same thing, pick one and document it.

4. **Determinism and caching.** Mermaid renders are cached by content hash.
   If you change how anything is rendered, bump `CACHE_VERSION` in
   `mermaid_processor.py` so stale caches are invalidated.

5. **Portability.** Image links written into derived Markdown are relative;
   environment variables (`META`, `PREAMBLE`, `MMDC`, …) let machines with
   different layouts build the same documents. Prefer relative paths and
   overridable defaults in anything you add.

6. **Small, single-purpose tools.** Each preprocessor does one transformation
   and is independently runnable from the command line. Keep new steps in
   that shape rather than growing the shell script into a monolith.

## When contributing

- Update `compile/README.md` (and root `README.md` if architecture changes) whenever you add a file, flag, or environment variable to the pipeline.
- Keep this file's project map and principles in sync with reality.
- Verify your change end-to-end with `testfiles/` before handing it off.
- Match the existing comment style: files open with a banner explaining what
  they are and how they are consumed.
