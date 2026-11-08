# Markdown Renderer Test 4: Tables and Layout

This file checks that tables (long, wide, and awkward ones) do not break the page, and that **text size and spacing stay consistent** everywhere. Each section ends with an *Expected* note.

**Things to watch for while reading:**

- Table text should be the same size as (or very slightly smaller than) body text, never tiny and never huge.
- The page itself must never scroll sideways. A wide table should scroll inside its own container.
- Gaps between headings, paragraphs, lists, and tables should look even and deliberate, with no large empty gaps and no elements glued together.

---

## 1. Baseline: A Small Table

Body text directly before a table. The gap between this line and the table should match the gap used elsewhere in this document.

| Feature | Supported | Notes |
|---------|:---------:|-------|
| Code highlighting | Yes | Fenced blocks |
| Math | Yes | KaTeX or MathJax |
| Mermaid | Yes | Diagrams |
| Tables | You tell me | This is the test |

Body text directly after the table. It should not touch the table border, and the gap should not be larger than the gap above.

**Expected:** a compact table with visible borders or row separators, centered "Supported" column, and even spacing before and after.

---

## 2. Alignment

| Left aligned | Center aligned | Right aligned |
|:-------------|:--------------:|--------------:|
| apple | 1 | 1.00 |
| banana split | 22 | 22.50 |
| cherry | 333 | 333.75 |
| a much longer left cell value | center | 4,444.00 |

**Expected:** left column flush left, middle centered, right column flush right with numbers lined up on the right edge.

---

## 3. Very Wide Table (20 Columns)

This table is far wider than any screen. The page must not gain a horizontal scrollbar. Only the table area should scroll, or the columns should shrink and wrap sensibly.

| Col1 | Col2 | Col3 | Col4 | Col5 | Col6 | Col7 | Col8 | Col9 | Col10 | Col11 | Col12 | Col13 | Col14 | Col15 | Col16 | Col17 | Col18 | Col19 | Col20 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1c1 | r1c2 | r1c3 | r1c4 | r1c5 | r1c6 | r1c7 | r1c8 | r1c9 | r1c10 | r1c11 | r1c12 | r1c13 | r1c14 | r1c15 | r1c16 | r1c17 | r1c18 | r1c19 | r1c20 |
| r2c1 | r2c2 | r2c3 | r2c4 | r2c5 | r2c6 | r2c7 | r2c8 | r2c9 | r2c10 | r2c11 | r2c12 | r2c13 | r2c14 | r2c15 | r2c16 | r2c17 | r2c18 | r2c19 | r2c20 |
| r3c1 | r3c2 | r3c3 | r3c4 | r3c5 | r3c6 | r3c7 | r3c8 | r3c9 | r3c10 | r3c11 | r3c12 | r3c13 | r3c14 | r3c15 | r3c16 | r3c17 | r3c18 | r3c19 | r3c20 |
| r4c1 | r4c2 | r4c3 | r4c4 | r4c5 | r4c6 | r4c7 | r4c8 | r4c9 | r4c10 | r4c11 | r4c12 | r4c13 | r4c14 | r4c15 | r4c16 | r4c17 | r4c18 | r4c19 | r4c20 |
| r5c1 | r5c2 | r5c3 | r5c4 | r5c5 | r5c6 | r5c7 | r5c8 | r5c9 | r5c10 | r5c11 | r5c12 | r5c13 | r5c14 | r5c15 | r5c16 | r5c17 | r5c18 | r5c19 | r5c20 |
| r6c1 | r6c2 | r6c3 | r6c4 | r6c5 | r6c6 | r6c7 | r6c8 | r6c9 | r6c10 | r6c11 | r6c12 | r6c13 | r6c14 | r6c15 | r6c16 | r6c17 | r6c18 | r6c19 | r6c20 |
| r7c1 | r7c2 | r7c3 | r7c4 | r7c5 | r7c6 | r7c7 | r7c8 | r7c9 | r7c10 | r7c11 | r7c12 | r7c13 | r7c14 | r7c15 | r7c16 | r7c17 | r7c18 | r7c19 | r7c20 |
| r8c1 | r8c2 | r8c3 | r8c4 | r8c5 | r8c6 | r8c7 | r8c8 | r8c9 | r8c10 | r8c11 | r8c12 | r8c13 | r8c14 | r8c15 | r8c16 | r8c17 | r8c18 | r8c19 | r8c20 |

Text after the wide table. This paragraph must be exactly the width of other paragraphs, not stretched to the table width.

**Expected:** page width unchanged, table scrolls inside itself, this paragraph wraps normally.

---

## 4. Long Cell Content

| Short | Long text cell | Unbreakable string |
|-------|----------------|--------------------|
| a | Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. | AVeryLongUnbrokenStringWithNoSpacesThatCouldEasilyOverflowTheCellAndBreakTheLayoutIfTheRendererDoesNotHandleItProperly1234567890 |
| b | Short | https://example.com/a/very/long/url/path/that/has/no/spaces/and/keeps/going/and/going/and/going/until/it/overflows?query=1&other=2 |
| c | Medium length text that wraps once or twice in a normal sized column. | `inline_code_that_is_also_quite_long_and_unbreakable_to_test_code_cells` |

**Expected:** long text wraps inside its cell. Unbreakable strings either wrap, scroll, or get truncated, but never push the page wider than the screen.

---

## 5. Long Table (60 Rows)

Row count test. The table should render fully, with consistent row height and no row text overlapping.

| ID | Username | Status | Balance | Created |
|---:|:---------|:------:|--------:|:--------|
| 001 | user_001 | Suspended | 971.19 | 2026-07-21 |
| 002 | user_002 | Active | 75.68 | 2026-02-12 |
| 003 | user_003 | Active | 932.64 | 2026-04-02 |
| 004 | user_004 | Active | 445.53 | 2026-02-08 |
| 005 | user_005 | Active | 565.54 | 2026-01-27 |
| 006 | user_006 | Active | 971.28 | 2026-11-21 |
| 007 | user_007 | Active | 591.74 | 2026-07-02 |
| 008 | user_008 | Pending | 48.71 | 2026-03-10 |
| 009 | user_009 | Archived | 148.69 | 2026-02-19 |
| 010 | user_010 | Suspended | 574.87 | 2026-03-04 |
| 011 | user_011 | Pending | 382.12 | 2026-09-23 |
| 012 | user_012 | Active | 578.07 | 2026-10-07 |
| 013 | user_013 | Archived | 697.68 | 2026-07-25 |
| 014 | user_014 | Suspended | 477.74 | 2026-08-12 |
| 015 | user_015 | Suspended | 255.23 | 2026-12-25 |
| 016 | user_016 | Pending | 84.73 | 2026-05-17 |
| 017 | user_017 | Archived | 897.43 | 2026-12-15 |
| 018 | user_018 | Suspended | 624.09 | 2026-02-17 |
| 019 | user_019 | Archived | 169.96 | 2026-06-05 |
| 020 | user_020 | Archived | 432.05 | 2026-11-03 |
| 021 | user_021 | Suspended | 349.88 | 2026-06-20 |
| 022 | user_022 | Archived | 594.58 | 2026-02-27 |
| 023 | user_023 | Active | 968.34 | 2026-08-23 |
| 024 | user_024 | Active | 63.93 | 2026-12-10 |
| 025 | user_025 | Archived | 292.91 | 2026-07-22 |
| 026 | user_026 | Suspended | 24.59 | 2026-06-06 |
| 027 | user_027 | Active | 506.07 | 2026-04-25 |
| 028 | user_028 | Suspended | 133.94 | 2026-04-13 |
| 029 | user_029 | Archived | 939.63 | 2026-02-06 |
| 030 | user_030 | Archived | 412.70 | 2026-05-05 |
| 031 | user_031 | Archived | 885.70 | 2026-05-23 |
| 032 | user_032 | Archived | 368.87 | 2026-07-08 |
| 033 | user_033 | Pending | 85.22 | 2026-03-08 |
| 034 | user_034 | Pending | 13.62 | 2026-10-06 |
| 035 | user_035 | Suspended | 289.00 | 2026-03-14 |
| 036 | user_036 | Suspended | 625.72 | 2026-06-05 |
| 037 | user_037 | Active | 468.99 | 2026-11-26 |
| 038 | user_038 | Archived | 408.51 | 2026-07-04 |
| 039 | user_039 | Archived | 650.51 | 2026-01-07 |
| 040 | user_040 | Active | 214.56 | 2026-03-04 |
| 041 | user_041 | Suspended | 616.06 | 2026-02-01 |
| 042 | user_042 | Pending | 550.12 | 2026-06-20 |
| 043 | user_043 | Active | 73.26 | 2026-10-13 |
| 044 | user_044 | Pending | 650.32 | 2026-06-20 |
| 045 | user_045 | Suspended | 486.15 | 2026-02-28 |
| 046 | user_046 | Archived | 478.61 | 2026-08-10 |
| 047 | user_047 | Active | 148.13 | 2026-12-11 |
| 048 | user_048 | Suspended | 491.88 | 2026-03-17 |
| 049 | user_049 | Active | 211.67 | 2026-06-05 |
| 050 | user_050 | Active | 777.67 | 2026-05-21 |
| 051 | user_051 | Active | 713.33 | 2026-09-12 |
| 052 | user_052 | Pending | 365.98 | 2026-04-18 |
| 053 | user_053 | Suspended | 652.28 | 2026-10-26 |
| 054 | user_054 | Pending | 826.30 | 2026-07-24 |
| 055 | user_055 | Pending | 205.66 | 2026-08-12 |
| 056 | user_056 | Active | 29.35 | 2026-08-09 |
| 057 | user_057 | Pending | 710.77 | 2026-06-15 |
| 058 | user_058 | Suspended | 978.46 | 2026-02-08 |
| 059 | user_059 | Active | 233.60 | 2026-04-11 |
| 060 | user_060 | Pending | 495.79 | 2026-10-27 |

Paragraph after the long table, confirming normal layout resumes.

**Expected:** all 60 rows present, numbers right aligned, status centered, even row heights, and the paragraph above sits at normal width and size.

---

## 6. Rich Content Inside Cells

| Type | Rendered | Source |
|------|----------|--------|
| Bold / italic | **bold** and *italic* and ***both*** | `**bold**` |
| Inline code | `const x = 1;` | backticks |
| Link | [Anthropic](https://www.anthropic.com) | `[text](url)` |
| Inline math | $E = mc^2$ | `$E = mc^2$` |
| Fraction | $\frac{a}{b}$ | `\frac` |
| Sum | $\sum_{i=1}^{n} i^2$ | `\sum` |
| Strikethrough | ~~removed~~ | `~~text~~` |
| Escaped pipe | a \| b | `\|` |
| Emoji | 🚀 ✅ ❌ | unicode |
| Line break | first<br>second | `<br>` |
| Empty cell | | (blank) |
| HTML | <kbd>Ctrl</kbd> + <kbd>C</kbd> | `<kbd>` |

**Expected:** each rendered cell shows formatting, not raw syntax. Math cells must not make their rows taller than other rows by a visible, ugly amount. The empty cell stays empty.

---

## 7. Tables Without Header Padding and With Odd Pipes

Minimal syntax (no outer pipes):

Name | Value
--- | ---
alpha | 1
beta | 2

Uneven source spacing (should render identically to a clean table):

|Name|Value|
|:--|--:|
|alpha|1|
|   beta   |   2   |

**Expected:** both render as normal two-column tables, and extra whitespace in the source has no effect.

---

## 8. Table Next to Other Blocks

A list, then a table, then code, then a quote. Spacing should be uniform between each.

- First item
- Second item
- Third item

| A | B |
|---|---|
| 1 | 2 |

```python
print("code block right after a table")
```

> A blockquote right after code.

| Quoted table follows | Value |
|----------------------|-------|
| row | 1 |

**Expected:** each block is separated from the next by the same comfortable gap. Nothing is jammed together, and nothing has a huge empty gap.

---

## 9. Text Size and Spacing Audit

# Heading 1
## Heading 2
### Heading 3
#### Heading 4
##### Heading 5
###### Heading 6

Each heading above should be visibly smaller than the previous one, with H6 still readable, and no giant gaps between them.

Normal paragraph text. This is the reference size. Everything else in the document should look proportional to it. Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.

A second paragraph directly after the first. The gap between these two paragraphs is the standard paragraph gap.

A third paragraph with a hard break after this sentence.  
This line follows a hard break, so the gap should be smaller than a paragraph gap.

**Tight list** (no blank lines between items):

- Item one
- Item two
- Item three
  - Nested item
  - Another nested item
    - Deeply nested item

**Loose list** (blank lines between items):

1. First item

2. Second item

3. Third item

**Ordered list that starts at 5:**

5. Five
6. Six
7. Seven

**Task list:**

- [x] Done item
- [ ] Open item

Inline `code` inside a sentence should not change the line height, and **bold**, *italic*, and $x^2$ inline math should not make that line taller than its neighbors.

Line with inline math $\frac{a}{b}$ and $\sum_{i=0}^{n} i$ and another line below it to compare line spacing between them.

A line without any math to compare against.

**Expected:** consistent line height, monotonic heading sizes, tight lists tighter than loose lists, and inline math not creating oversized lines.

---

## 10. Code, Math, and Mermaid Next to Tables (Width Check)

A wide code block should scroll inside itself:

```text
| this | is | a | very | wide | line | of | text | that | goes | on | and | on | and | on | past | the | edge | of | the | screen | to | test | overflow |
```

A wide equation should scroll or fit, without widening the page:

$$
a_1 + a_2 + a_3 + a_4 + a_5 + a_6 + a_7 + a_8 + a_9 + a_{10} + a_{11} + a_{12} + a_{13} + a_{14} + a_{15} + a_{16} + a_{17} + a_{18} + a_{19} + a_{20} = S
$$

A wide Mermaid diagram should scale or scroll:

```mermaid
flowchart LR
    A1[Step 1] --> A2[Step 2] --> A3[Step 3] --> A4[Step 4] --> A5[Step 5] --> A6[Step 6] --> A7[Step 7] --> A8[Step 8] --> A9[Step 9] --> A10[Step 10]
```

Closing paragraph. If this is the same width and size as the first paragraph in the document, the layout survived every test above.

---

## Final Checklist

- [ ] No horizontal page scrollbar anywhere in the document
- [ ] Wide table scrolls inside its container or shrinks gracefully
- [ ] Long unbreakable strings and URLs do not overflow the page
- [ ] All 60 rows of the long table render, with aligned columns
- [ ] Table text is similar in size to body text
- [ ] Alignment markers (`:---`, `:---:`, `---:`) are honored
- [ ] Bold, code, links, and math all render inside cells
- [ ] Escaped pipe shows a literal `|`; `<br>` makes a line break in a cell
- [ ] Gaps before and after tables match gaps between other blocks
- [ ] Headings shrink steadily from H1 to H6
- [ ] Tight lists are tighter than loose lists; hard breaks are tighter than paragraphs
- [ ] Inline math does not make its line taller than surrounding lines
- [ ] Wide code, equation, and diagram stay inside the page width
