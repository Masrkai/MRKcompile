// =============================================================================
//  Typst preamble for ABANC proposal
//  Injected via: pandoc --include-in-header=preamble.typ
//  Runs after pandoc's own `#set` rules, so these override template defaults.
// =============================================================================

// --- Page geometry + running footer -----------------------------------------
#set page(
  paper: "a4",
  margin: (top: 2.5cm, bottom: 2.5cm, left: 2.2cm, right: 2.2cm),
  header: context {
  },
  footer: context {
    set align(center)
    set text(size: 9pt, fill: luma(120))
    counter(page).display("1")
  },
)

// --- Body typography ---------------------------------------------------------
#set text(size: 11pt)
//#set par(justify: true, leading: 0.7em) 

// --- Headings ----------------------------------------------------------------
#show heading.where(level: 1): set block(above: 1.6em, below: 0.9em)
#show heading.where(level: 2): set block(above: 1.3em, below: 0.6em)
#show heading.where(level: 3): set block(above: 1.1em, below: 0.5em)
#show heading.where(level: 4): set block(above: 0.9em, below: 0.4em)

// --- Matrix delimiter workaround ---------------------------------------------
// Pandoc's LaTeX->Typst math conversion emits mat(delim: "||", ...) for
// \begin{vmatrix}/\begin{Vmatrix}, but Typst requires a delimiter to be
// exactly one character. Map "||" to the U+2016 double vertical line.
#let mat(delim: auto, ..args) = math.mat(
  delim: if delim == "||" { "\u{2016}" } else { delim },
  ..args,
)


// --- Tables ------------------------------------------------------------------
#set table(
  stroke: 0.4pt + luma(180),
  inset: (x: 4pt, y: 3pt),
)

#show table.cell.where(y: 0): set text(weight: "bold")
#show table: set block(above: 0.8em, below: 1.0em)

// --- Figures and captions ----------------------------------------------------
#show figure: set block(above: 0.8em, below: 1.0em)
#show figure.caption: set text(size: 9.5pt, style: "italic")

// --- Code blocks and inline code --------------------------------------------
#show raw.where(block: true): set block(
  fill: luma(246),
  inset: 8pt,
  radius: 3pt,
  width: 100%,
)
#show raw.where(block: true): set text(size: 9pt, font: "DejaVu Sans Mono")
#show raw.where(block: false): set text(
  size: 10pt,
  font: "DejaVu Sans Mono",
  fill: rgb("#8b0000"),
)

// --- Links -------------------------------------------------------------------
#show link: set text(fill: rgb("#1a5fb4"))

// --- Equations ---------------------------------------------------------------
#set math.equation(numbering: "(1)")

// --- Block quotes ------------------------------------------------------------
#show quote.where(block: true): set block(
  fill: luma(248),
  inset: (x: 12pt, y: 8pt),
  radius: 3pt,
  width: 100%,
)

