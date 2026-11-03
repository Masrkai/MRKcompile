#!/usr/bin/env python3
"""
Extract ```mermaid fenced code blocks from a Markdown file, render each to a
PDF via `mmdc --pdfFit`, and rewrite the block as a normal Markdown image
reference pointing at the rendered PDF.

Captions
--------
If the first non-empty line inside a mermaid fence is a comment of the form::

    %% caption: Figure 1: My diagram.

that text is used as the image alt text, which Pandoc promotes to a
figure caption under the `implicit_figures` extension. If no caption is
given, a generic placeholder is used so that Pandoc still treats the
image as a figure.

Usage
-----
    preprocess_mermaid.py input.md output.md [--diagrams-dir diagrams]
                                            [--mmdc mmdc]
                                            [--strict]

The original input.md is never modified. output.md is a derived file with
mermaid blocks replaced by image links; feed THAT to pandoc.

Behaviour on failure
--------------------
By default, a failed mmdc render leaves the original mermaid fence in the
output and prints a warning to stderr, so that pandoc still produces a
PDF (with a raw code block instead of a diagram). Pass --strict to abort
instead.

Notes
-----
* Image links written into the output Markdown are RELATIVE to the output
  file's directory, so the document is portable across machines.
* Rendered PDFs are cached by content hash. Bump CACHE_VERSION if you change
  the mmdc invocation (e.g. different --pdfFit options) to invalidate.
* Fails fast with a clear message if mmdc is missing.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Bump this if you change the mmdc command line so caches are invalidated.
CACHE_VERSION = "v2"

FENCE_RE = re.compile(
    r"^(?P<indent>[ \t]*)```mermaid[ \t]*\n"
    r"(?P<code>.*?)"
    r"^(?P=indent)```[ \t]*$",
    re.DOTALL | re.MULTILINE,
)

CAPTION_RE = re.compile(r"^\s*%%\s*caption\s*:\s*(?P<cap>.+?)\s*$", re.MULTILINE)

MMDC_TIMEOUT_SECONDS = 120


def extract_caption(code: str) -> str | None:
    """Return the caption if a ``%% caption: ...`` line is present."""
    m = CAPTION_RE.search(code)
    return m.group("cap").strip() if m else None


def render_block(code: str, diagrams_dir: Path, mmdc_path: str) -> Path:
    """Render mermaid `code` to a PDF, caching by content hash. Returns the PDF path."""
    digest = hashlib.sha256(
        f"{CACHE_VERSION}\x00{code}".encode("utf-8")
    ).hexdigest()[:16]
    out_pdf = diagrams_dir / f"mermaid-{digest}.pdf"

    if out_pdf.exists():
        return out_pdf  # cache hit, skip re-render

    diagrams_dir.mkdir(parents=True, exist_ok=True)
    tmp_mmd = diagrams_dir / f"mermaid-{digest}.mmd"
    tmp_mmd.write_text(code, encoding="utf-8")

    cmd = [
        mmdc_path,
        "--pdfFit",
        "--input", str(tmp_mmd),
        "--output", str(out_pdf),
    ]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=MMDC_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        tmp_mmd.unlink(missing_ok=True)
        out_pdf.unlink(missing_ok=True)
        raise RuntimeError(
            f"mmdc timed out after {MMDC_TIMEOUT_SECONDS}s for block {digest}"
        )
    except FileNotFoundError as e:
        tmp_mmd.unlink(missing_ok=True)
        raise RuntimeError(f"mmdc executable not found: {mmdc_path!r}") from e

    if result.returncode != 0:
        tmp_mmd.unlink(missing_ok=True)
        out_pdf.unlink(missing_ok=True)
        raise RuntimeError(
            f"mmdc failed for block hash {digest}:\n{result.stderr.strip()}"
        )

    tmp_mmd.unlink(missing_ok=True)
    return out_pdf


def process(
    input_path: Path,
    output_path: Path,
    diagrams_dir: Path,
    mmdc_path: str,
    strict: bool,
) -> None:
    text = input_path.read_text(encoding="utf-8")

    matches = list(FENCE_RE.finditer(text))
    if not matches:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(text, encoding="utf-8")
        print(f"No mermaid blocks found in {input_path.name}; copied unchanged.")
        return

    pieces: list[str] = []
    last_end = 0
    rendered = 0
    failed = 0

    for m in matches:
        pieces.append(text[last_end:m.start()])
        code = m.group("code")
        caption = extract_caption(code)

        try:
            pdf_path = render_block(code, diagrams_dir, mmdc_path)
        except RuntimeError as e:
            if strict:
                raise SystemExit(str(e))
            print(f"WARNING: {e}", file=sys.stderr)
            print(
                f"         leaving mermaid block unchanged in {output_path.name}",
                file=sys.stderr,
            )
            # Emit the original mermaid fence verbatim so pandoc renders
            # it as a code block. Not pretty, but loud and visible.
            pieces.append(m.group(0))
            failed += 1
            last_end = m.end()
            continue

        # Relative path from the OUTPUT file's directory to the rendered PDF.
        # os.path.relpath (not Path.relative_to) handles sibling directories
        # and produces a portable, machine-independent link.
        try:
            rel = os.path.relpath(pdf_path, start=output_path.parent)
        except ValueError:
            # Different drives on Windows — fall back to absolute.
            rel = str(pdf_path)

        alt = caption or f"Mermaid diagram {rendered + 1}"
        pieces.append(f"![{alt}]({Path(rel).as_posix()})")

        last_end = m.end()
        rendered += 1

    pieces.append(text[last_end:])
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("".join(pieces), encoding="utf-8")

    msg = f"{input_path.name}: replaced {rendered} mermaid block(s) -> {output_path.name}"
    if failed:
        msg += f" ({failed} failed, left as code blocks)"
    print(msg)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument(
        "--diagrams-dir",
        type=Path,
        default=Path("diagrams"),
        help="directory to cache rendered mermaid PDFs (default: ./diagrams)",
    )
    ap.add_argument(
        "--mmdc",
        default="mmdc",
        help="path to the mmdc executable (default: mmdc on PATH)",
    )
    ap.add_argument(
        "--strict",
        action="store_true",
        help="abort on the first mmdc failure instead of falling back",
    )
    args = ap.parse_args()

    if shutil.which(args.mmdc) is None and not Path(args.mmdc).exists():
        raise SystemExit(
            f"mmdc executable not found: {args.mmdc!r}\n"
            f"Install it with:  npm install -g @mermaid-js/mermaid-cli"
        )

    process(args.input, args.output, args.diagrams_dir, args.mmdc, args.strict)


if __name__ == "__main__":
    main()