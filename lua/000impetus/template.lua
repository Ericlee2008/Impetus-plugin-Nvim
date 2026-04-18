local store = require("impetus.store")

local M = {}

local function display_width(s)
  return vim.fn.strdisplaywidth(s)
end

local function pad_right(s, width)
  local n = width - display_width(s)
  if n <= 0 then
    return s
  end
  return s .. string.rep(" ", n)
end

local function compute_widths(rows)
  local widths = {}
  for _, row in ipairs(rows) do
    for i, col in ipairs(row) do
      local w = display_width(col)
      widths[i] = math.max(widths[i] or 0, w)
    end
  end
  return widths
end

local function format_row(row, widths)
  local out = {}
  for i, col in ipairs(row) do
    out[#out + 1] = pad_right(col, widths[i] or display_width(col))
  end
  return table.concat(out, ",  ")
end

local function blank_row(widths, field_count)
  if field_count <= 0 then
    return ""
  end
  local placeholders = {}
  for i = 1, field_count do
    local w = math.max(1, widths[i] or 1)
    placeholders[#placeholders + 1] = string.rep(" ", w)
  end
  return table.concat(placeholders, ",  ") .. ","
end

local function snippet_row(widths, field_count, start_index)
  local out = {}
  local idx = start_index
  for i = 1, field_count do
    local w = math.max(1, widths[i] or 1)
    out[#out + 1] = "${" .. idx .. ":" .. string.rep(" ", w) .. "}"
    idx = idx + 1
  end
  return table.concat(out, ",  ") .. ",", idx
end

local function build_block(keyword, use_snippet)
  local entry = store.get_keyword(keyword)
  if not entry then
    return keyword
  end

  local out = { keyword }
  local rows = entry.signature_rows or {}
  if #rows == 0 and entry.params and #entry.params > 0 then
    rows = { entry.params }
  end
  if entry.has_optional_title then
    out[#out + 1] = '"Optional title"'
  end

  local widths = compute_widths(rows)
  local snippet_index = 1

  for _, row in ipairs(rows) do
    local row_count = #row
    out[#out + 1] = "# " .. format_row(row, widths)
    if use_snippet then
      local line
      line, snippet_index = snippet_row(widths, row_count, snippet_index)
      out[#out + 1] = line
    else
      out[#out + 1] = blank_row(widths, row_count)
    end
  end

  return table.concat(out, "\n")
end

function M.keyword_block(keyword)
  return build_block(keyword, false)
end

function M.keyword_block_snippet(keyword)
  return build_block(keyword, true)
end

return M
