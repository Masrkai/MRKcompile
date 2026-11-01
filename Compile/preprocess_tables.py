#!/usr/bin/env python3
import sys
import re

def parse_markdown_table(table_lines):
    if len(table_lines) < 2:
        return table_lines

    rows = []
    for line in table_lines:
        parts = [p.strip() for p in line.strip().split('|')]
        cells = parts[1:-1]
        rows.append(cells)

    if len(rows) < 2:
        return table_lines

    header = rows[0]
    separator = rows[1]
    body_rows = rows[2:]

    aligns = []
    for sep in separator:
        sep = sep.strip()
        if sep.startswith(':') and sep.endswith(':'):
            aligns.append('center')
        elif sep.endswith(':'):
            aligns.append('right')
        else:
            aligns.append('left')

    num_cols = len(header)

    def format_cell(text, is_header=False):
        t = text.strip()
        # Clean up LaTeX math commands for Typst
        t = re.sub(r'\\mathbf\{(.*?)\}', r'bold(\1)', t)
        t = re.sub(r'\\text\{(.*?)\}', r'"\1"', t)
        t = t.replace(r'\approx', 'approx').replace(r'\pm', 'plus.minus').replace(r'\varphi', 'phi.alt')
        # Convert markdown bold **foo** to *foo*
        t = re.sub(r'\*\*(.*?)\*\*', r'*\1*', t)
        if is_header:
            if not (t.startswith('*') and t.endswith('*')):
                t = f"*{t}*"
        return f"[{t}]"

    typst_lines = []
    typst_lines.append("```{=typst}")
    typst_lines.append("#table(")
    typst_lines.append(f"  columns: ({', '.join(['1fr'] * num_cols)}),")
    typst_lines.append(f"  inset: 8pt,")
    typst_lines.append(f"  align: ({', '.join(aligns)}),")

    # Header cells
    for cell in header:
        formatted = format_cell(cell, is_header=True)
        typst_lines.append(f"  {formatted},")

    # Body cells
    for row in body_rows:
        for cell in row:
            formatted = format_cell(cell, is_header=False)
            typst_lines.append(f"  {formatted},")

    typst_lines.append(")")
    typst_lines.append("```")
    return typst_lines

def process_file(input_path, output_path):
    with open(input_path, 'r', encoding='utf-8') as f:
        content = f.read()

    lines = content.splitlines()
    new_lines = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip().startswith('|') and line.strip().endswith('|'):
            table_lines = []
            while i < len(lines) and lines[i].strip().startswith('|') and lines[i].strip().endswith('|'):
                table_lines.append(lines[i])
                i += 1
            if len(table_lines) >= 2 and '---' in table_lines[1]:
                typst_table = parse_markdown_table(table_lines)
                new_lines.extend(typst_table)
            else:
                new_lines.extend(table_lines)
        else:
            new_lines.append(line)
            i += 1

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write("\n".join(new_lines) + "\n")

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: preprocess_tables.py <input.md> <output.md>")
        sys.exit(1)
    process_file(sys.argv[1], sys.argv[2])
