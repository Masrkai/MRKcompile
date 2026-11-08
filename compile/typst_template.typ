// =============================================================================
//  Typst document template for the MRKcompile pipeline.
//  Consumed via: pandoc --template=typst_template.typ
//
//  Based on pandoc 3.7.0.2's default Typst template (extracted with
//  `pandoc -D typst`, conf() expanded and adjusted). Deviations from the
//  default, all deliberate:
//
//  1. Page geometry (paper size, margins, header/footer) is NOT set here.
//     preamble.typ is the single source of truth for styling — the stock
//     template's `set page(...)` ran AFTER the include-in-header preamble
//     and silently overrode it.
//  2. The visible title block renders title, author NAMES and date only.
//     Subtitle, keywords, affiliation and email web-letter metadata stay out
//     of the rendered page (PDF text extraction must not leak them); abstract
//     is not printed at all.
//  3. TOC is still opt-in via `toc: true` in the document front matter.
//
//  If you upgrade pandoc, re-check this file against the new default
//  (`pandoc -D typst`).
// =============================================================================

#let horizontalrule = line(start: (25%,0%), end: (75%,0%))

#show terms: it => {
  it.children
    .map(child => [
      #strong[#child.term]
      #block(inset: (left: 1.5em, top: -0.4em))[#child.description]
      ])
    .join()
}

#set table(
  inset: 6pt,
  stroke: none
)

#show figure.where(
  kind: table
): set figure.caption(position: $if(table-caption-position)$$table-caption-position$$else$top$endif$)

#show figure.where(
  kind: image
): set figure.caption(position: $if(figure-caption-position)$$figure-caption-position$$else$bottom$endif$)

#let content-to-string(content) = {
  if content.has("text") {
    content.text
  } else if content.has("children") {
    content.children.map(content-to-string).join("")
  } else if content.has("body") {
    content-to-string(content.body)
  } else if content == [ ] {
    " "
  }
}
#let conf(
  title: none,
  authors: (),
  date: none,
  lang: "en",
  region: "US",
  font: (),
  fontsize: 11pt,
  sectionnumbering: none,
  doc,
) = {
  set document(
    title: title,
    author: authors.map(author => content-to-string(author.name)),
  )
  set par(justify: true)
  set text(lang: lang,
           region: region,
           font: font,
           size: fontsize)
  set heading(numbering: sectionnumbering)

  place(top, float: true, scope: "parent", clearance: 4mm)[
  #if title != none {
    align(center)[#block(inset: 2em)[
      #text(weight: "bold", size: 1.5em)[#title]
    ]]
  }

  #if authors != none and authors != [] {
    let count = authors.len()
    let ncols = calc.min(count, 3)
    grid(
      columns: (1fr,) * ncols,
      row-gutter: 1.5em,
      ..authors.map(author =>
          align(center)[
            #content-to-string(author.name)
          ]
      )
    )
  }

  #if date != none {
    align(center)[#block(inset: 1em)[
      #date
    ]]
  }
  ]

  doc
}

$if(smart)$
$else$
#set smartquote(enabled: false)

$endif$
$for(header-includes)$
$header-includes$

$endfor$
#show: doc => conf(
$if(title)$
  title: [$title$],
$endif$
$if(author)$
  authors: (
$for(author)$
$if(author.name)$
    ( name: [$author.name$], ),
$else$
    ( name: [$author$], ),
$endif$
$endfor$
    ),
$endif$
$if(date)$
  date: [$date$],
$endif$
$if(lang)$
  lang: "$lang$",
$endif$
$if(region)$
  region: "$region$",
$endif$
$if(mainfont)$
  font: ("$mainfont$",),
$endif$
$if(fontsize)$
  fontsize: $fontsize$,
$endif$
$if(section-numbering)$
  sectionnumbering: "$section-numbering$",
$endif$
  doc,
)

$for(include-before)$
$include-before$

$endfor$
$if(toc)$
#outline(
  title: auto,
  depth: $toc-depth$
);
$endif$

$body$

$if(citations)$
$if(csl)$

#set bibliography(style: "$csl$")
$elseif(bibliographystyle)$

#set bibliography(style: "$bibliographystyle$")
$endif$
$if(bibliography)$

#bibliography($for(bibliography)$"$bibliography$"$sep$,$endfor$)
$endif$
$endif$
$for(include-after)$

$include-after$
$endfor$
