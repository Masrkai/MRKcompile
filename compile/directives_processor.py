#!/usr/bin/env python3
"""
Expand the pipeline's custom Markdown directives into raw Typst blocks.

Recognised directives (a directive is matched by exact occurrence anywhere
in the text — including inside code fences — mirroring the historical
behaviour this tool was extracted from):

    /toc        ->  ```{=typst}\n#outline()\n```
    /breakpage  ->  ```{=typst}\n#pagebreak()\n```
    /newpage    ->  ```{=typst}\n#pagebreak()\n```
    /pagebreak  ->  ```{=typst}\n#pagebreak()\n```

TOC handling depends on the mode:

* Default (per-file) mode: *every* occurrence of ``/toc`` is replaced with
  the outline block, matching what happens when each document owns its
  own table of contents.
* ``--single-toc`` (stitched mode): only the *first* occurrence of
  ``/toc`` is replaced with the outline block; all later occurrences are
  deleted (not replaced), so a stitched document has exactly one TOC.
  This matches the documented behaviour of ``compile.sh -l``.

Usage
-----
    directives_processor.py input.md output.md [--single-toc]

The original input.md is never modified; write the expanded text to
output.md (which may equal input — the whole file is rewritten then).
Feed the output to pandoc, not the original.

This step is deliberately text-only (no AST) and is kept byte-compatible
with the inline expander it replaces in compile.sh. Do not "fix" it to
ignore directives inside code fences without bumping the documentation
in compile/README.md: that would be a behaviour change.
"""

import argparse
from pathlib import Path

OUTLINE_BLOCK = "```{=typst}\n#outline()\n```"
PAGEBREAK_BLOCK = "```{=typst}\n#pagebreak()\n```"


def expand(text: str, single_toc: bool) -> str:
    """Expand directives in a Markdown document. Order matters only for
    readability here; no directive string is a substring of another."""
    if single_toc:
        # First /toc becomes the outline, later ones are deleted.
        parts = text.split("/toc")
        if len(parts) > 1:
            text = parts[0] + OUTLINE_BLOCK + "".join(parts[1:])
    else:
        text = text.replace("/toc", OUTLINE_BLOCK)
    text = text.replace("/breakpage", PAGEBREAK_BLOCK)
    text = text.replace("/newpage", PAGEBREAK_BLOCK)
    text = text.replace("/pagebreak", PAGEBREAK_BLOCK)
    return text


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument(
        "--single-toc",
        action="store_true",
        help="stitched mode: replace only the first /toc, delete the rest",
    )
    args = ap.parse_args()

    text = args.input.read_text(encoding="utf-8")
    expanded = expand(text, args.single_toc)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(expanded, encoding="utf-8")
    print(f"{args.input.name}: directives expanded -> {args.output.name}")


if __name__ == "__main__":
    main()
