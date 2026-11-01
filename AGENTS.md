# AGENTS.md — Instructions for AI agents

This repository has a maintainer guide that defines how the project is
organized and the principles it follows.

## Mandatory reading

1. **Before doing any work in this repository, read `contributors.md`**
   (or `contributing.md`) and root `README.md`. They contain the project map,
   pipeline architecture, usage instructions, and design principles.
2. **Also read `compile/README.md`** before touching anything under
   `compile/` — it documents the build pipeline, its conventions, and the
   environment variables it supports.

## Coherence duty

- **Watch for updates.** Other maintainers and agents may edit these files
  between your sessions. Always re-read `contributors.md` and
  `compile/README.md` at the start of a task — do not rely on a cached
  memory of their contents.
- **Keep everything coherent.** Whenever your change affects behavior,
  structure, or usage, update the documentation in the same change:
  - new/renamed/removed files → update the project map in `contributors.md`,
    root `README.md`, and the file table in `compile/README.md`;
  - new flags, environment variables, or pipeline steps → update
    `compile/README.md` and root `README.md`;
  - changes to design decisions or conventions → update the Principles
    section in `contributors.md`.
- **Never contradict the principles** in `contributors.md` (sources stay
  pristine, failures are loud, one source of truth per concern, caching is
  versioned, paths are portable, tools stay small and single-purpose). If a
  task seems to require violating one, stop and flag the conflict instead of
  silently breaking the invariant.

## Verification

Before finishing any task that changes the pipeline, run it against the
sample documents:

```bash
cd testfiles && ../compile/run_typst_final.sh
```

Report what you changed, which docs you updated, and the verification result.

## Human Oversight

This project and all work performed by AI agents is under the direct oversight of a human maintainer who is ultimately responsible for all code and documentation, and who is soon to graduate with a Computer Science degree.
