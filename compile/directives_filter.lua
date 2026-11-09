-- =============================================================================
--  directives_filter.lua — expand the pipeline's custom Markdown directives
--  into raw Typst (pandoc Lua filter).
--
--  Consumed by: compile.sh via pandoc's --lua-filter (run before
--  table_filter.lua so directives inside table cells are expanded while the
--  tables still exist as AST). It replaces the text-based
--  directives_processor.py, which was the previous incarnation of this step;
--  the shell script no longer calls that preprocessor.
--
--  Recognised directives:
--
--      /toc        ->  #outline()
--      /breakpage  ->  #pagebreak()
--      /newpage    ->  #pagebreak()
--      /pagebreak  ->  #pagebreak()
--
--  Behaviour (mirrors directives_processor.py):
--
--  * A directive is matched by exact substring occurrence ANYWHERE in the
--    text - including inside code fences. That is intentional and preserved
--    from the pipeline's history; do not "fix" it here (compile/README.md
--    documents it).
--  * A paragraph whose lines are each a bare directive becomes one raw Typst
--    block per line (matching the fenced raw blocks the old text
--    preprocessor produced). Any other occurrence becomes a raw inline Typst
--    command at the occurrence's position.
--  * Code blocks (and inline code spans) keep their code shape: the directive
--    text inside them is replaced by the raw fence literal, exactly as the
--    old preprocessor did, so the replacement stays visible in the rendered
--    code block.
--  * Stitched builds ("compile.sh -l") pass -M single-toc=true: only the
--    FIRST /toc becomes the outline and all later occurrences are deleted
--    (not replaced), so a stitched document has exactly one TOC.
--
--  NOTE: pandoc invokes filter handlers in a fresh environment containing
--  only the returned handler table, so all helpers are locals and the
--  handlers are exported at the end; no globals are used for calls.
-- =============================================================================

local OUTLINE_TY = '#outline()'
local PAGEBREAK_TY = '#pagebreak()'
-- Literal replacement used inside code blocks: the raw fence the old
-- preprocessor wrote into the Markdown, kept so code blocks render the same.
local OUTLINE_FENCE = "```{=typst}\n#outline()\n```"
local PAGEBREAK_FENCE = "```{=typst}\n#pagebreak()\n```"

local TOC = "/toc"
local PAGEBREAKS = { "/breakpage", "/newpage", "/pagebreak" }

local single_toc = false
local toc_seen = false

local next_directive, expand_code_text, expand_inlines, expand_text_pieces
local run_directive, split_runs, expand_table_directives, expand_blocks

-- Are we in stitched mode (-M single-toc=true)? Accept either a boolean or
-- the string "true" (-M sets a MetaString).
local function is_true(v)
  if v == true then return true end
  if type(v) == "string" and v == "true" then return true end
  return false
end

Pandoc = function(doc)
  single_toc = is_true(doc.meta["single-toc"])

  doc.blocks = expand_blocks(doc.blocks)
  return doc
end

-- =============================================================================
--  String-level expansion (used inside code blocks and code spans)
-- =============================================================================

next_directive = function(text, from)
  local best_at, best_name = nil, nil
  local p = text:find(TOC, from, true)
  if p then best_at, best_name = p, TOC end
  for _, name in ipairs(PAGEBREAKS) do
    p = text:find(name, from, true)
    if p and (best_at == nil or p < best_at) then
      best_at, best_name = p, name
    end
  end
  return best_at, best_name
end

expand_code_text = function(text)
  local out = {}
  local i = 1
  while i <= #text do
    local at, name = next_directive(text, i)
    if not at then break end
    out[#out + 1] = text:sub(i, at - 1)
    if name == TOC then
      if not (single_toc and toc_seen) then
        out[#out + 1] = OUTLINE_FENCE
      end
      toc_seen = true
    else
      out[#out + 1] = PAGEBREAK_FENCE
    end
    i = at + #name
  end
  out[#out + 1] = text:sub(i)
  return table.concat(out)
end

-- =============================================================================
--  Inline-level expansion
-- =============================================================================

local INLINE_CONTAINERS = {
  Cite = true, Emph = true, Link = true, Quoted = true,
  Span = true, Strikeout = true, Strong = true, Subscript = true,
  Superscript = true, Underline = true,
}

expand_inlines = function(inlines)
  local out = {}
  for _, el in ipairs(inlines) do
    local t = el.t
    if t == "Str" then
      local pieces = expand_text_pieces(el.text)
      for _, piece in ipairs(pieces) do
        out[#out + 1] = piece
      end
    elseif t == "Code" then
      el.text = expand_code_text(el.text)
      out[#out + 1] = el
    elseif t == "Image" then
      -- alt-text lives in .caption in pandoc's Lua AST
      el.caption = expand_inlines(el.caption or {})
      out[#out + 1] = el
    elseif t == "Note" then
      el.content = expand_blocks(el.content)
      out[#out + 1] = el
    elseif INLINE_CONTAINERS[t] then
      el.content = expand_inlines(el.content)
      out[#out + 1] = el
    else
      out[#out + 1] = el
    end
  end
  return out
end

-- Replace string occurrences: returns a list of Str / raw inline elements.
expand_text_pieces = function(text)
  local pieces = {}
  local i = 1
  while i <= #text do
    local at, name = next_directive(text, i)
    if not at then break end
    if at > i then pieces[#pieces + 1] = pandoc.Str(text:sub(i, at - 1)) end
    i = at + #name
    if name == TOC then
      if not (single_toc and toc_seen) then
        pieces[#pieces + 1] = pandoc.RawInline('typst', OUTLINE_TY)
      end
      toc_seen = true
    else
      pieces[#pieces + 1] = pandoc.RawInline('typst', PAGEBREAK_TY)
    end
  end
  if i <= #text then
    pieces[#pieces + 1] = pandoc.Str(text:sub(i))
  end
  return pieces
end

-- =============================================================================
--  Block-level expansion
-- =============================================================================

-- A run of inlines (paragraph text between line breaks) that is exactly one
-- directive (possibly surrounded by whitespace) -> its name, else nil.
run_directive = function(run)
  local s = pandoc.utils.stringify(pandoc.Pandoc{ pandoc.Plain(run) })
  s = s:match("^%s*(.-)%s*$")
  if s == TOC then return TOC end
  for _, name in ipairs(PAGEBREAKS) do
    if s == name then return name end
  end
  return nil
end

-- Split an inline list into runs at SoftBreak/LineBreak boundaries.
split_runs = function(inlines)
  local runs = {}
  local cur = {}
  for _, el in ipairs(inlines) do
    if el.t == "SoftBreak" or el.t == "LineBreak" then
      runs[#runs + 1] = cur
      cur = {}
    else
      cur[#cur + 1] = el
    end
  end
  runs[#runs + 1] = cur
  return runs
end

expand_table_directives = function(tbl)
  local function cell(cell)
    if cell then cell.content = expand_blocks(cell.content) end
  end
  if tbl.head then
    for _, row in ipairs(tbl.head.rows) do
      for _, c in ipairs(row.cells) do cell(c) end
    end
  end
  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.body) do
      for _, c in ipairs(row.cells) do cell(c) end
    end
  end
  if tbl.foot then
    for _, row in ipairs(tbl.foot.rows) do
      for _, c in ipairs(row.cells) do cell(c) end
    end
  end
end

expand_blocks = function(blocks)
  local out = {}
  for _, bl in ipairs(blocks) do
    local t = bl.t
    if t == "CodeBlock" then
      bl.text = expand_code_text(bl.text)
      out[#out + 1] = bl
    elseif t == "Para" or t == "Plain" then
      local runs = split_runs(bl.content)
      local all_directive = #runs > 0
      for _, run in ipairs(runs) do
        if #run == 0 or not run_directive(run) then
          all_directive = false
          break
        end
      end
      if all_directive then
        for _, run in ipairs(runs) do
          local d = run_directive(run)
          if d == TOC then
            if not (single_toc and toc_seen) then
              out[#out + 1] = pandoc.RawBlock('typst', OUTLINE_TY)
            end
            toc_seen = true
          else
            out[#out + 1] = pandoc.RawBlock('typst', PAGEBREAK_TY)
          end
        end
      else
        bl.content = expand_inlines(bl.content)
        out[#out + 1] = bl
      end
    elseif t == "BlockQuote" or t == "Div" or t == "Figure" then
      bl.content = expand_blocks(bl.content)
      out[#out + 1] = bl
    elseif t == "BulletList" or t == "OrderedList" then
      for i, item in ipairs(bl.content) do
        bl.content[i] = expand_blocks(item)
      end
      out[#out + 1] = bl
    elseif t == "DefinitionList" then
      for i, pair in ipairs(bl.content) do
        bl.content[i] = { expand_inlines(pair[1]), expand_blocks(pair[2]) }
      end
      out[#out + 1] = bl
    elseif t == "Table" then
      expand_table_directives(bl)
      out[#out + 1] = bl
    else
      out[#out + 1] = bl
    end
  end
  return out
end

return {
  Pandoc = Pandoc,
}
