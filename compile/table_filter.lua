-- table-to-typst.lua
-- Pandoc Lua filter to convert Markdown tables into native Typst #table(...) blocks.

local function inlines_to_typst(contents)
  local doc = pandoc.Pandoc(contents)
  local res = pandoc.write(doc, 'typst')
  -- Remove trailing newlines and whitespace
  res = res:gsub("^%s+", ""):gsub("%s+$", "")
  return res
end

local function align_to_typst(alignment)
  if alignment == 'AlignLeft' then
    return 'left'
  elseif alignment == 'AlignRight' then
    return 'right'
  elseif alignment == 'AlignCenter' then
    return 'center'
  else
    return 'left'
  end
end

function Table(tbl)
  local colspecs = tbl.colspecs
  local aligns = {}
  for _, colspec in ipairs(colspecs) do
    local align = colspec[1]
    table.insert(aligns, align_to_typst(align))
  end

  local rows = {}
  
  if tbl.head and tbl.head.rows then
    for _, row in ipairs(tbl.head.rows) do
      table.insert(rows, {is_header = true, cells = row.cells})
    end
  end

  if tbl.bodies then
    for _, body in ipairs(tbl.bodies) do
      if body.body then
        for _, row in ipairs(body.body) do
          table.insert(rows, {is_header = false, cells = row.cells})
        end
      end
    end
  end

  if #rows == 0 then
    return nil
  end

  local lines = {}
  table.insert(lines, "#table(")
  
  -- columns
  local col_defs = {}
  for _ = 1, #colspecs do
    table.insert(col_defs, "1fr")
  end
  table.insert(lines, "  columns: (" .. table.concat(col_defs, ", ") .. "),")
  
  -- align
  local align_defs = {}
  for _, a in ipairs(aligns) do
    table.insert(align_defs, a)
  end
  table.insert(lines, "  align: (" .. table.concat(align_defs, ", ") .. "),")
  
  -- inset
  table.insert(lines, "  inset: 8pt,")

  -- cells
  for _, r in ipairs(rows) do
    for _, cell in ipairs(r.cells) do
      local cell_text = inlines_to_typst(cell.contents)
      if r.is_header then
        table.insert(lines, "  [*" .. cell_text .. "*],")
      else
        table.insert(lines, "  [" .. cell_text .. "],")
      end
    end
  end

  table.insert(lines, ")")

  local typst_code = table.concat(lines, "\n")
  return pandoc.RawBlock("typst", typst_code)
end
