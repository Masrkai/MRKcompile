-- =============================================================================
--  table_filter.lua — convert Markdown tables into native Typst #table blocks
--  (pandoc Lua filter).
--
--  Consumed by: compile.sh via pandoc's --lua-filter (run right after
--  directives_filter.lua, so directives already expanded inside table cells
--  survive). It replaces the regex-based table_processor.py, which was the
--  previous incarnation of this step; the shell script no longer calls that
--  preprocessor.
--
--  Why: pandoc's Typst table writer drops raw-HTML in table cells (<br>,
--  <kbd>), emits stray semicolons after inline markup, and produces
--  percentage-width columns that let unbreakable strings overflow the page.
--  This filter emits tables that:
--    - always fit the page width (proportional fr columns),
--    - keep the alignment markers (:---, :---:, ---:),
--    - render bold/italic/code/links/math inside cells (the Typst writer
--      converts math from LaTeX to Typst natively),
--    - translate <br> to #linebreak() and strip <kbd> wrappers,
--    - give unbreakable tokens (> 25 chars, e.g. URLs) zero-width-space
--      break points so they wrap inside their cell instead of overflowing.
--
--  Behaviour on failure
--  --------------------
--  Warnings go to stderr (loud) but do not abort the build: a table that
--  reaches the Typst writer unconverted produces degraded output, never a
--  broken pipeline. pandoc itself aborts loudly on Lua errors.
-- =============================================================================

local ZWSP = "\u{200B}"
local TOKEN_BREAK_LIMIT = 25    -- tokens longer than this get break points
local TOKEN_BREAK_SPACING = 20  -- break point every N characters of a long token

-- Codepoint length, falling back to byte length on invalid UTF-8.
local function cp_len(s)
  return utf8.len(s) or #s
end

-- =============================================================================
--  Cell conversion
-- =============================================================================

local function typst_escape_string(text)
  -- Escape plain text for a Typst string literal (only \ and ").
  return text:gsub("\\", "\\\\"):gsub('"', '\\"')
end

-- Insert break opportunities (ZWSP) in a long plain-text token. URLs get
-- breaks at punctuation (- / ? & = : . _), anything else gets a break every
-- TOKEN_BREAK_SPACING characters. The optional weak horizontal space in front
-- of the token gives typst the initial break opportunity it otherwise misses
-- when a long token starts a cell (only for normal text, never inside raw
-- code spans). Ports table_processor.py's break_long_tokens.
local function break_str(text)
  local chars = {}
  for _, cp in utf8.codes(text) do
    chars[#chars + 1] = utf8.char(cp)
  end
  local out = { pandoc.RawInline('typst', '#h(0pt, weak: true)') }
  local acc = {}
  local run = 0
  for i = 1, #chars do
    acc[#acc + 1] = chars[i]
    run = run + 1
    if run >= TOKEN_BREAK_SPACING
        or (i < #chars and run >= 10 and chars[i]:match('^[-/?&=:._]$')) then
      acc[#acc + 1] = ZWSP
      run = 0
    end
  end
  out[#out + 1] = pandoc.Str(table.concat(acc))
  return out
end

-- Same as break_str but for content inside code spans: a bare ZWSP prefix
-- (same effect inside code spans, where typst markup is text).
local function break_code(text)
  local chars = {}
  for _, cp in utf8.codes(text) do
    chars[#chars + 1] = utf8.char(cp)
  end
  local acc = { ZWSP }
  local run = 0
  for i = 1, #chars do
    acc[#acc + 1] = chars[i]
    run = run + 1
    if run >= TOKEN_BREAK_SPACING
        or (i < #chars and run >= 10 and chars[i]:match('^[-/?&=:._]$')) then
      acc[#acc + 1] = ZWSP
      run = 0
    end
  end
  return table.concat(acc)
end

local INLINE_CONTAINERS = {
  Cite = true, Emph = true, Link = true, Quoted = true, Span = true,
  Strikeout = true, Strong = true, Subscript = true, Superscript = true,
  Underline = true,
}

local function is_html(el)
  local f = tostring(el.format or "")
  return f == "html" or f == "tex_html"
end

-- Transform one inline list. break_long controls whether Str tokens get the
-- break treatment: true only for the cell's top-level plain text (matching
-- the old preprocessor, which never broke tokens inside markup delimiters).
local function transform_inlines(inlines, break_long)
  local out = {}
  for _, el in ipairs(inlines) do
    local t = el.t
    if t == "Str" then
      if break_long and cp_len(el.text) > TOKEN_BREAK_LIMIT then
        for _, piece in ipairs(break_str(el.text)) do
          out[#out + 1] = piece
        end
      else
        out[#out + 1] = el
      end
    elseif t == "Code" then
      if cp_len(el.text) > TOKEN_BREAK_LIMIT then
        el.text = break_code(el.text)
      end
      out[#out + 1] = el
    elseif t == "RawInline" then
      if is_html(el) then
        local compact = el.text:lower():gsub("%s+", "")
        if compact == "<br>" or compact == "<br/>" then
          out[#out + 1] = pandoc.RawInline('typst', '#linebreak()')
        elseif compact == "<kbd>" or compact == "</kbd>" then
          -- simple <kbd> wrappers are dropped
        else
          out[#out + 1] = el
        end
      else
        out[#out + 1] = el
      end
    elseif t == "Image" then
      -- images -> #image("path") (stashed before links, so nested image
      -- links keep working: the link text retains the raw inline)
      local src = typst_escape_string(el.src)
      local alt = pandoc.utils.stringify(el.caption or el.content or {})
        :gsub("^%s+", ""):gsub("%s+$", "")
      local extra = ""
      if alt ~= "" then extra = ', alt: "' .. typst_escape_string(alt) .. '"' end
      out[#out + 1] = pandoc.RawInline('typst', '#image("' .. src .. '"' .. extra .. ")")
    elseif INLINE_CONTAINERS[t] then
      el.content = transform_inlines(el.content, false)
      out[#out + 1] = el
    else
      out[#out + 1] = el
    end
  end
  return out
end

-- Convert one cell (a list of Blocks) to Typst markup.
--
-- pandoc's Typst writer inserts a disambiguation `;` right after any
-- writer-produced `#func[...]` element when something follows it (text, a
-- sibling, or the enclosing bracket). That trailing `;` is the well-known
-- writer artifact this step used to avoid; the old regex preprocessor built
-- the strings itself and never inserted one. strip_writer_semis drops one
-- such `;` after every closing bracket of the functions listed below. Raw
-- typst passed through verbatim (our #image(...), #h(...), raw directives)
-- never gets a separator and is excluded, so literal `;` characters in cell
-- text are kept.
local INSERTING_FUNCS = {
  strong = true, emph = true, strike = true, sub = true, sup = true,
  super = true, underline = true, smallcaps = true, footnote = true,
  link = true,
}

-- Convert writer escapes back to plain characters: drop the writer's
-- `\/` escapes (a bare "/" never needs escaping in typst markup). Paired
-- backslashes ("\\", i.e. a literal backslash in the source) are left
-- intact, as are string literals ("..." in #image/#link arguments).
local function unescape_slash_pairs(s)
  local out = {}
  local i = 1
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    if c == '\\' then
      local nxt = s:sub(i + 1, i + 1)
      if nxt == '/' then
        out[#out + 1] = '/'
      else
        out[#out + 1] = s:sub(i, i + 1)
      end
      i = i + 2
    elseif c == '"' then
      -- string literal: copy verbatim up to the closing quote
      local j = i + 1
      while j <= n do
        local d = s:sub(j, j)
        if d == '\\' then j = j + 2
        elseif d == '"' then break
        else j = j + 1 end
      end
      out[#out + 1] = s:sub(i, j)
      i = j + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  -- Single-char code spans containing "|" come out escaped ("\|") which
  -- would render the backslash visually; undo that one.
  return table.concat(out):gsub("`\\|`", "`|`")
end

local function strip_writer_semis(s)
  local out = {}
  local stack = {}  -- one entry per open [...]: was_func = true if the
                    -- bracket belongs to a writer-inserting function
  local i = 1
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    if c == '\\' then
      out[#out + 1] = s:sub(i, i + 1)
      i = i + 2
    elseif c == '"' then
      -- typst string literal: copy verbatim up to the closing quote
      local j = i + 1
      while j <= n do
        local d = s:sub(j, j)
        if d == '\\' then j = j + 2
        elseif d == '"' then break
        else j = j + 1 end
      end
      out[#out + 1] = s:sub(i, j)
      i = j + 1
    elseif c == '[' then
      local prev = s:sub(i - 1, i - 1)
      local name, was_func = "", false
      if prev:match('[%w_]') then
        local j = i - 1
        while j >= 1 and s:sub(j, j):match('[%w_]') do j = j - 1 end
        name = s:sub(j + 1, i - 1)
        was_func = #name > 0 and s:sub(j, j) == '#'
          and s:sub(j - 1, j - 1) ~= '\\' and INSERTING_FUNCS[name] == true
      elseif prev == ')' then
        -- #link("url")[content]: the bracket follows a (...) argument
        local k = i - 2
        while k >= 1 and s:sub(k, k) ~= '(' do k = k - 1 end
        local m = k - 1
        while m >= 1 and s:sub(m, m):match('[%w_]') do m = m - 1 end
        name = s:sub(m + 1, k - 1)
        was_func = #name > 0 and s:sub(m, m) == '#'
          and s:sub(m - 1, m - 1) ~= '\\' and INSERTING_FUNCS[name] == true
      end
      stack[#stack + 1] = { was_func = was_func }
      out[#out + 1] = c
      i = i + 1
    elseif c == ']' then
      out[#out + 1] = c
      local top = stack[#stack]
      stack[#stack] = nil
      i = i + 1
      if top and top.was_func and s:sub(i, i) == ';' then
        i = i + 1  -- drop exactly one inserted disambiguation semicolon
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local function cell_to_typst(blocks)
  local newblocks = {}
  for _, bl in ipairs(blocks) do
    if bl.t == "Para" or bl.t == "Plain" then
      newblocks[#newblocks + 1] = pandoc.Plain(transform_inlines(bl.content, true))
    else
      newblocks[#newblocks + 1] = bl
    end
  end
  if #newblocks == 0 then return "" end
  -- wide columns + no wrapping: keep each cell on one line (the writer's
  -- default 72-column wrap would insert hard newlines into the #table block
  -- we emit).
  local s = pandoc.write(pandoc.Pandoc(newblocks), 'typst', { columns = 1000000 })
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  -- The writer escapes BOTH slashes of a "//" pair ("https:\/\/...") to keep
  -- them from starting a comment; "/" needs no escape in typst markup, so
  -- undo it to read like the old preprocessor's output.
  s = unescape_slash_pairs(s)
  return strip_writer_semis(s)
end

local function with_brackets(strs)
  local parts = {}
  for _, s in ipairs(strs) do
    parts[#parts + 1] = "[" .. s .. "]"
  end
  return parts
end

-- Proportional fr column widths from the longest cell of each column. Very
-- short columns are floored so narrow headers/cells still fit without
-- leaking into the neighbor column. Cells are already converted to Typst
-- markup when this runs, so the measured length covers markup and URLs.
local function weighted_columns(ncols, cell_strs)
  local weights = {}
  for col = 1, ncols do
    local longest = 1
    for _, cells in ipairs(cell_strs) do
      if cells[col] then
        local len = cp_len(cells[col])
        if len > longest then longest = len end
      end
    end
    weights[col] = math.max(10, math.min(longest, 60))
  end
  local parts = {}
  for _, w in ipairs(weights) do parts[#parts + 1] = w .. "fr" end
  return "  columns: (" .. table.concat(parts, ", ") .. ",),"
end

local function align_to_typst(a)
  if a == "AlignRight" then return "right" end
  if a == "AlignCenter" then return "center" end
  return "left"  -- AlignLeft / AlignDefault, meant to match the old separator handling
end

function Table(tbl)
  local ncols = #tbl.colspecs
  if ncols == 0 then return nil end

  local header_cells = nil
  if tbl.head and #tbl.head.rows > 0 then
    header_cells = tbl.head.rows[1].cells
  end

  local body_rows = {}
  for _, body in ipairs(tbl.bodies or {}) do
    for _, row in ipairs(body.body) do
      body_rows[#body_rows + 1] = row.cells
    end
  end

  -- Convert all cells once, then lay out the table.
  local header_strs = nil
  if header_cells then
    header_strs = {}
    for _, c in ipairs(header_cells) do
      header_strs[#header_strs + 1] = cell_to_typst(c.content)
    end
  end
  local cell_strs = {}
  if header_strs then cell_strs[#cell_strs + 1] = header_strs end
  for _, cells in ipairs(body_rows) do
    local strs = {}
    for _, c in ipairs(cells) do
      strs[#strs + 1] = cell_to_typst(c.content)
    end
    cell_strs[#cell_strs + 1] = strs
  end

  local lines = {}
  -- Extremely wide tables get a smaller font and tighter inset so their
  -- contents still fit the page; narrow tables keep the defaults.
  local wide = ncols > 8
  if wide then
    lines[#lines + 1] = ncols <= 14 and "#text(size: 9pt)[" or "#text(size: 8pt)["
  end
  lines[#lines + 1] = "#table("
  lines[#lines + 1] = weighted_columns(ncols, cell_strs)

  local aligns = {}
  for _, cs in ipairs(tbl.colspecs) do
    aligns[#aligns + 1] = align_to_typst(cs[1])
  end
  lines[#lines + 1] = "  align: (" .. table.concat(aligns, ", ") .. ",),"

  if wide then
    lines[#lines + 1] = "  inset: (x: 3pt, y: 8pt),"
  else
    lines[#lines + 1] = "  inset: 8pt,"
  end

  local body_start = header_strs and 2 or 1
  -- markdown tables parsed from pipe syntax always carry a header here
  if header_strs then
    lines[#lines + 1] = "  table.header(" .. table.concat(with_brackets(header_strs), ", ") .. ",),"
    lines[#lines + 1] = "  table.hline(),"
  end
  for i = body_start, #cell_strs do
    lines[#lines + 1] = "  " .. table.concat(with_brackets(cell_strs[i]), ", ") .. ","
  end
  lines[#lines + 1] = ")"
  if wide then lines[#lines + 1] = "]" end

  local blocks = { pandoc.RawBlock('typst', table.concat(lines, "\n")) }
  -- Keep a non-empty table caption visible: the old text preprocessor left
  -- the caption line outside the table (it was not part of the table run);
  -- emulate that so caption text is not silently dropped.
  local cap = pandoc.utils.stringify(tbl.caption):gsub("^%s+", ""):gsub("%s+$", "")
  if cap ~= "" then
    blocks[#blocks + 1] = pandoc.Plain({ pandoc.Str(cap) })
  end
  return blocks
end
