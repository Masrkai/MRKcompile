#!/usr/bin/env python3
# =============================================================================
#  table_processor.py — convert Markdown pipe tables into native Typst
#  #table(...) raw blocks.
#
#  Consumed by: compile.sh (step 4). Input derived Markdown in resolved/,
#  output is the same derived Markdown with pipe tables replaced by raw Typst.
#  The source .md is never touched.
#
#  Why: pandoc's Typst table writer drops raw-HTML in table cells
#  (<br>, <kbd>), emits stray semicolons after inline markup, and produces
#  percentage-width columns that let unbreakable strings overflow the page.
#  This preprocessor produces tables that:
#    - always fit the page width (proportional fr columns),
#    - keep the Markdown alignment markers (:---, :---:, ---:),
#    - render bold/italic/code/links/math inside cells (math is converted
#      from LaTeX to Typst via `pandoc -f latex -t typst`, cached per span),
#    - translate <br> to #linebreak() and strip simple <kbd> wrappers,
#    - give unbreakable tokens (> 25 chars, e.g. URLs) zero-width-space
#      break points so they wrap inside their cell instead of overflowing.
#
#  Usage:
#      table_processor.py <input.md> <output.md>
#
#  Behaviour:
#  - A block is converted when line 1 and line 2 are both table rows and
#    line 2 is a separator row (every cell is :---, :---:, ---: or ---).
#  - Outer pipes are optional (GFM style) and escaped pipes (\|) are kept
#    as literal pipe characters in the output cell.
#  - Code fences (``` / ~~~) are skipped: tables inside fences are left alone.
#  - Unconverted (non-table) lines pass through untouched.
#  - pandoc is required only when a cell contains $math$; if that conversion
#    fails, a warning is printed and the raw LaTeX is kept (visible, loud).
# =============================================================================

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
import os

ZWSP = "\u200b"
TOKEN_BREAK_LIMIT = 25   # tokens longer than this get break points
TOKEN_BREAK_SPACING = 20 # break point every N characters of a long token

MATH_CACHE: dict[str, str] = {}

SEP_RE = re.compile(r"^:?-+:?$")
BOLD_RE = re.compile(r"\*\*(.+?)\*\*", re.DOTALL)
BOLD_ITALIC_RE = re.compile(r"\*\*\*(.+?)\*\*\*", re.DOTALL)
ITALIC_RE = re.compile(r"(?<!\*)\*([^*\n]+)\*(?!\*)")
STRIKE_RE = re.compile(r"~~(.+?)~~", re.DOTALL)
CODE_RE = re.compile(r"(`+)([^`]+)\1")
IMAG_RE = re.compile(r"!\[([^\]]*)\]\(((?:[^()\s]|\([^()]*\))+)\)")
LINK_RE = re.compile(r"\[([^\]]*)\]\(((?:[^()\s]|\([^()]*\))+)\)")
MATH_RE = re.compile(r"\$\$?\s*(.+?)\s*\$\$?", re.DOTALL)
BR_RE = re.compile(r"<br\s*/?>", re.IGNORECASE)
KBD_RE = re.compile(r"</?kbd>", re.IGNORECASE)


def split_row(line: str) -> list[str]:
    """Split a table row on unescaped pipes into raw cell strings.

    Handles escapes, strips the boundary cells introduced by outer pipes
    (only when outer pipes are actually present). An escaped pipe (\\|) does
    not split the cell and renders as a literal pipe character.
    """
    cells: list[str] = []
    buf: list[str] = []
    i = 0
    n = len(line)
    text = line.strip()
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            nxt = text[i + 1]
            if nxt == "|":
                # \ | : escaped pipe -> literal pipe, not a cell boundary
                buf.append("|")
            else:
                # other escapes (\\, \frac, ...) keep the backslash
                buf.append(c)
                buf.append(nxt)
            i += 2
            continue
        if c == "|":
            cells.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    cells.append("".join(buf))

    # Boundary empties from outer pipes: only drop if the pipe was really there.
    if text.startswith("|") and cells and cells[0].strip() == "":
        cells.pop(0)
    if text.endswith("|") and cells and cells[-1].strip() == "":
        cells.pop()
    return cells


def is_separator_row(cells: list[str]) -> bool:
    return bool(cells) and all(SEP_RE.match(c.strip()) for c in cells)


def align_of(cells: list[str]) -> str:
    """Map one separator cell to a Typst alignment constant."""
    s = cells.strip()
    left = s.startswith(":")
    right = s.endswith(":")
    if left and right:
        return "center"
    if right:
        return "right"
    return "left"


def latex_math_to_typst(latex: str) -> str | None:
    """Convert a LaTeX math span to Typst markup via pandoc. Cached.

    Returns the Typst markup (including surrounding $...$) or None on failure.
    """
    key = latex.strip()
    if key in MATH_CACHE:
        return MATH_CACHE[key]
    if shutil.which("pandoc") is None:
        return None
    try:
        result = subprocess.run(
            ["pandoc", "-f", "latex", "-t", "typst"],
            input=f"${key}$\n",
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.SubprocessError:
        return None
    if result.returncode != 0:
        return None
    out = result.stdout.strip()
    if not out.startswith("$"):
        return None
    MATH_CACHE[key] = out
    return out


def typst_escape_string(text: str) -> str:
    """Escape a plain text for a Typst string literal (only \\ and ")."""
    return text.replace("\\", "\\\\").replace('"', '\\"')


def typst_escape(text: str) -> str:
    """Escape Typst markup special characters in a plain text fragment."""
    text = text.replace("\\", "\\\\")
    for ch in "#*_`[]$<>@":
        text = text.replace(ch, "\\" + ch)
    return text


def break_long_tokens(text: str, allow_prefix: bool = True) -> str:
    """Insert break opportunities (ZWSP) in tokens longer than the limit.

    URLs get breaks at punctuation (- / ? & = : . _), anything else gets a
    break every TOKEN_BREAK_SPACING characters. Keeps long URLs and CamelCase
    identifiers from overflowing their cell. The optional weak horizontal
    space in front of the token gives typst the initial break opportunity it
    otherwise misses when a long token starts a cell (only for normal text,
    never inside raw code spans).
    """
    parts = re.split(r"(\s+)", text)
    out = []
    for part in parts:
        if len(part) > TOKEN_BREAK_LIMIT and not re.match(r"^\s+$", part):
            broken: list[str] = []
            run = 0
            for idx, ch in enumerate(part):
                broken.append(ch)
                run += 1
                if run >= TOKEN_BREAK_SPACING or (
                    idx + 1 < len(part)
                    and run >= 10
                    and ch in "-/?&=:._"
                ):
                    broken.append(ZWSP)
                    run = 0
            if allow_prefix:
                broken.insert(0, "#h(0pt, weak: true)")
            else:
                # same effect inside code spans, where typst markup is text
                broken.insert(0, ZWSP)
            out.append("".join(broken))
        else:
            out.append(part)
    return "".join(out)


def convert_cell(markdown: str, source: str) -> str:
    """Convert one Markdown cell to Typst markup."""
    cell = markdown.strip()
    placeholders: dict[str, str] = {}
    counter = 0

    def stash(typst: str) -> str:
        nonlocal counter
        key = f"\x00{counter}\x00"
        placeholders[key] = typst
        counter += 1
        return key

    # 1. inline code first: nothing inside it may be interpreted as markup
    def sub_code(m: re.Match) -> str:
        ticks, content = m.group(1), m.group(2)
        # give long code tokens a chance to wrap inside their cell
        if len(content) > TOKEN_BREAK_LIMIT:
            content = break_long_tokens(content, allow_prefix=False)
        return stash(ticks + content + ticks)

    cell = CODE_RE.sub(sub_code, cell)

    # 2. images -> #image("path") (stashed first so nested image links work:
    #    [![alt](img)](url) then matches as a plain link around the stash)
    def sub_image(m: re.Match) -> str:
        src = typst_escape_string(m.group(2))
        alt = typst_escape_string(m.group(1))
        extra = f", alt: \"{alt}\"" if alt else ""
        return stash(f'#image("{src}"{extra})')

    cell = IMAG_RE.sub(sub_image, cell)

    # 3. links -> #link("url")[text]
    def sub_link(m: re.Match) -> str:
        url = typst_escape_string(m.group(2))
        label = typst_escape(m.group(1))
        return stash(f'#link("{url}")[{label}]')

    cell = LINK_RE.sub(sub_link, cell)

    # 4. inline math -> Typst math (via pandoc)
    def sub_math(m: re.Match) -> str:
        conv = latex_math_to_typst(m.group(1))
        if conv is None:
            print(
                f"WARNING: could not convert math {m.group(0)!r} in cell of "
                f"{source}; keeping raw LaTeX (it may not render)",
                file=sys.stderr,
            )
            return typst_escape(m.group(0))
        return stash(conv)

    cell = MATH_RE.sub(sub_math, cell)

    # 5. bold-italic / bold / italic / strikethrough -> markup functions
    cell = BOLD_ITALIC_RE.sub(lambda m: stash(f"#strong[#emph[{m.group(1)}]]"), cell)
    cell = BOLD_RE.sub(lambda m: stash(f"#strong[{m.group(1)}]"), cell)
    cell = ITALIC_RE.sub(lambda m: stash(f"#emph[{m.group(1)}]"), cell)
    cell = STRIKE_RE.sub(lambda m: stash(f"#strike[{typst_escape(m.group(1))}]"), cell)

    # 6. <br> -> line break; simple <kbd> wrappers are dropped
    cell = BR_RE.sub(lambda m: stash("#linebreak()"), cell)
    cell = KBD_RE.sub("", cell)


    # 7. escape what is left, then restore the stashed spans.
    # Loop until stable: stashed spans may themselves contain inner keys.
    cell = typst_escape(cell)
    cell = break_long_tokens(cell)
    for _ in range(len(placeholders) + 1):
        before = cell
        for key, value in placeholders.items():
            cell = cell.replace(key, value)
        if cell == before:
            break
    return cell
    cell = break_long_tokens(cell)
    for key, value in placeholders.items():
        cell = cell.replace(key, value)
    return cell


def weighted_columns(rows: list[list[str]]) -> str:
    """Proportional fr column widths from the longest cell of each column.

    Very short columns are floored so narrow headers/cells still fit without
    leaking into the neighbor column.
    """
    ncols = max(len(r) for r in rows)
    weights = []
    for col in range(ncols):
        longest = max((len(row[col].strip()) for row in rows if col < len(row)), default=1)
        weights.append(max(10, min(longest, 60)))
    cols = ", ".join(f"{w}fr" for w in weights)
    return f"  columns: ({cols},),"


def build_typst_table(rows: list[list[str]], aligns: list[str], source: str) -> list[str]:
    """Render parsed rows (header first, then separator removed) as Typst."""
    ncols = len(rows[0])
    header, body = rows[0], rows[1:]

    out = ["```{=typst}"]
    # Extremely wide tables get a smaller font and tighter inset so their
    # contents still fit the page; narrow tables keep the defaults.
    wide = ncols > 8
    if wide:
        if ncols <= 14:
            out.append('#text(size: 9pt)[')
        else:
            out.append('#text(size: 8pt)[')
    out.append("#table(")
    out.append(weighted_columns(rows))
    align_list = ", ".join(aligns[:ncols] + ["auto"] * max(0, ncols - len(aligns)))
    out.append(f"  align: ({align_list},),")
    out.append("  inset: (x: 3pt, y: 8pt)," if wide else "  inset: 8pt,")

    header_cells = ", ".join(f"[{convert_cell(c, source)}]" for c in header)
    out.append(f"  table.header({header_cells},),")
    out.append("  table.hline(),")
    for row in body:
        padded = row + [""] * (ncols - len(row))
        cells = ", ".join(f"[{convert_cell(c, source)}]" for c in padded[:ncols])
        out.append(f"  {cells}," if cells else "  [],")
    out.append(")")
    if wide:
        out.append("]")
    out.append("```")
    return out


def convert_tables(content: str, source_name: str = "input") -> str:
    lines = content.splitlines()
    out: list[str] = []
    i = 0
    in_fence = False
    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()
        # Track code fences; never touch anything inside them.
        if re.match(r"^(`{3,}|~{3,})", stripped):
            in_fence = not in_fence
            out.append(line)
            i += 1
            continue
        if in_fence or "|" not in line:
            out.append(line)
            i += 1
            continue

        # Collect a run of consecutive candidate rows.
        run: list[str] = []
        while i < len(lines):
            cur = lines[i]
            if "|" in cur and not re.match(r"^(`{3,}|~{3,})", cur.lstrip()):
                run.append(cur)
                i += 1
            else:
                break
        if len(run) >= 2 and is_separator_row(split_row(run[1])):
            header_cells = split_row(run[0])
            sep_cells = split_row(run[1])
            if len(sep_cells) != len(header_cells):
                print(
                    f"WARNING: {source_name}: separator row has "
                    f"{len(sep_cells)} cells but header has {len(header_cells)}; "
                    "missing columns get left alignment",
                    file=sys.stderr,
                )
            aligns = [align_of(c) for c in sep_cells] + ["auto"] * 64
            rows = [header_cells] + [split_row(r) for r in run[2:]]
            out.extend(build_typst_table(rows, aligns, source_name))
        else:
            out.extend(run)

    return "\n".join(out) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", type=str)
    ap.add_argument("output", type=str)
    args = ap.parse_args()
    with open(args.input, encoding="utf-8") as f:
        content = f.read()
    converted = convert_tables(content, os.path.basename(args.input))
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(converted)


if __name__ == "__main__":
    main()
