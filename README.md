# MRKcompile

MRKcompile is a robust, modular document compilation pipeline that turns plain Markdown sources into professional, publication-quality typeset PDFs using **pandoc** and **Typst**, featuring automated **Mermaid diagram rendering** and **native Markdown table conversion**.

## Pipeline Architecture

The diagram below illustrates how `run_typst_final.sh` orchestrates preprocessors, templates, and typesetting engines to compile documents:

```mermaid
graph TD
    subgraph Input Documents & Config
        MD[Markdown Source .md]
        Meta[compile/meta.yaml<br/>Metadata & Config]
        Pre[compile/preamble.typ<br/>Styling & Preamble]
    end

    subgraph Preprocessing Pipeline (run_typst_final.sh)
        Res[1. Setup resolved/<br/>Isolate sources & relative paths]
        Mermaid[2. preprocess_mermaid.py<br/>```mermaid → Cached PDF Figures]
        Images[3. preprocess_images.py<br/>Remote HTTP(S) → Local Cache]
        Tables[4. preprocess_tables.py<br/>Pipe Tables → Native #table]
    end

    subgraph Compilation Engine
        Pandoc[5. Pandoc<br/>Markdown → Typst AST]
        Typst[6. Typst Compiler<br/>Typesetting + Preamble]
    end

    subgraph Output & Caching
        PDF[PDF Output<br/>PDF/filename.pdf]
        Cache[(Persistent Cache<br/>.cache/diagrams/, .cache/images/)]
    end

    MD --> Res
    Res --> Mermaid
    Mermaid --> Images
    Images --> Tables
    Tables --> Pandoc
    Meta --> Pandoc
    Pre --> Typst
    Pandoc --> Typst
    Typst --> PDF
    Mermaid -.-> Cache
    Images -.-> Cache
```

## Quick Start

### Prerequisites
- **pandoc** (Markdown to Typst conversion)
- **typst** (PDF typesetting engine)
- **python3** (runs preprocessors)
- **mmdc** (Mermaid CLI: `npm install -g @mermaid-js/mermaid-cli`, required only for diagrams)

### Building PDFs

Run the build script from the directory containing your `.md` files:

```bash
# Build all top-level *.md files in current directory
/path/to/MRKcompile/compile/run_typst_final.sh

# Build specific files
/path/to/MRKcompile/compile/run_typst_final.sh document.md
```

Outputs are generated in the `PDF/` directory.

## Project Structure

```
MRKcompile/
├── compile/                  ← Pipeline toolchain & templates
│   ├── run_typst_final.sh    ← Main build orchestrator
│   ├── preprocess_mermaid.py ← Renders mermaid code blocks to cached PDFs
│   ├── preprocess_images.py  ← Caches remote HTTP(S) images locally
│   ├── preprocess_tables.py  ← Converts markdown pipe tables to Typst tables
│   ├── preamble.typ          ← Typography, page geometry, and styling
│   ├── meta.yaml             ← Document metadata & defaults
│   └── README.md             ← Detailed build guide & environment options
├── testfiles/                ← Sample .md documents and end-to-end test suite
├── README.md                 ← Project overview & architecture (this file)
├── contributors.md           ← Maintainer & contributor guidelines
└── AGENTS.md                 ← Instructions for AI agents
```

## Documentation

- **Build Pipeline & Configuration:** See [`compile/README.md`](compile/README.md) for environment variables (`STRICT_MERMAID`, `KEEP_RESOLVED`, etc.), troubleshooting, and conventions.
- **Contributing & Principles:** See [`contributors.md`](contributors.md) for design philosophy (pristine sources, loud failures, deterministic caching).
