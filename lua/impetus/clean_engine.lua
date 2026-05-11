local commands = require("impetus.commands")
local store = require("impetus.store")

local trim = commands.trim
local strip_number_prefix = commands.strip_number_prefix
local parse_keyword = commands.parse_keyword
local split_keyword_blocks = commands.split_keyword_blocks
local is_comment_line = commands.is_comment_line
local is_blank_line = commands.is_blank_line
local is_comma_only_line = commands.is_comma_only_line
local is_meta_row = commands.is_meta_row

local function clean_current_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = split_keyword_blocks(lines)
  if #blocks == 0 then
    return 0, {}
  end

  local out = {}
  local removed = 0
  local entries = {}

  -- Preamble: blank/comment lines before the first keyword block
  for r = 1, blocks[1].start_row - 1 do
    local line = lines[r] or ""
    if is_comment_line(line) or is_blank_line(line) then
      removed = removed + 1
      entries[#entries + 1] = { row = r, line = line, reason = is_comment_line(line) and "comment" or "blank" }
    else
      out[#out + 1] = line
    end
  end

  for _, b in ipairs(blocks) do
    local keyword_upper = b.keyword:upper()
    local entry = store.get_keyword(keyword_upper)
    local sig_rows = entry and entry.signature_rows or nil
    local keyword_line = lines[b.start_row] or ""
    -- Normalize lowercase keyword to uppercase
    keyword_line = keyword_line:gsub(vim.pesc(b.keyword), keyword_upper)
    out[#out + 1] = keyword_line

    -- Gather non-comment lines inside the block
    local block_lines = {}
    local block_rows = {}
    for r = b.start_row + 1, b.end_row do
      local line = lines[r] or ""
      if is_comment_line(line) then
        removed = removed + 1
        entries[#entries + 1] = { row = r, line = line, reason = "comment" }
      else
        block_lines[#block_lines + 1] = line
        block_rows[#block_rows + 1] = r
      end
    end

    -- Remove leading blank lines (conservative: blank lines at the start of a block)
    while #block_lines > 0 and is_blank_line(block_lines[1]) do
      entries[#entries + 1] = { row = block_rows[1], line = block_lines[1], reason = "leading-blank" }
      table.remove(block_lines, 1)
      table.remove(block_rows, 1)
      removed = removed + 1
    end

    -- Remove trailing blank lines (conservative: blank lines at the end of a block)
    while #block_lines > 0 and is_blank_line(block_lines[#block_lines]) do
      entries[#entries + 1] = { row = block_rows[#block_rows], line = block_lines[#block_lines], reason = "trailing-blank" }
      table.remove(block_lines, #block_lines)
      table.remove(block_rows, #block_rows)
      removed = removed + 1
    end

    local data_row_idx = 0
    for i, line in ipairs(block_lines) do
      local drop = false
      local reason = nil

      if is_comma_only_line(line) then
        local expected = nil
        if sig_rows and sig_rows[data_row_idx + 1] then
          expected = #sig_rows[data_row_idx + 1]
        end
        if expected and expected > 1 then
          drop = false
          data_row_idx = data_row_idx + 1
        else
          drop = true
          reason = "comma-only"
        end
      else
        if not is_meta_row(line) then
          data_row_idx = data_row_idx + 1
        end
      end

      if drop then
        removed = removed + 1
        entries[#entries + 1] = { row = block_rows[i], line = line, reason = reason or "?" }
      else
        out[#out + 1] = line
      end
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  return removed, entries
end

local function split_keyword_blocks_with_unknown(lines)
  local blocks = {}
  local start_row, keyword = nil, nil
  for i, raw in ipairs(lines or {}) do
    local t = trim(strip_number_prefix(raw or ""))
    local kw = t:match("^(%*[%w_%-]+)")
    if kw then
      if start_row then
        blocks[#blocks + 1] = {
          keyword = keyword,
          start_row = start_row,
          end_row = i - 1,
        }
      end
      start_row = i
      keyword = kw
    end
  end
  if start_row then
    blocks[#blocks + 1] = {
      keyword = keyword,
      start_row = start_row,
      end_row = #lines,
    }
  end
  return blocks
end

local function advanced_clear_current_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = split_keyword_blocks_with_unknown(lines)
  if #blocks == 0 then
    return 0, {}
  end

  local out = {}
  local removed = 0
  local entries = {}

  -- Preamble: blank/comment lines before the first keyword block
  for r = 1, blocks[1].start_row - 1 do
    local line = lines[r] or ""
    if is_comment_line(line) or is_blank_line(line) then
      removed = removed + 1
      entries[#entries + 1] = { row = r, line = line, reason = is_comment_line(line) and "comment" or "blank" }
    else
      out[#out + 1] = line
    end
  end

  for _, b in ipairs(blocks) do
    local keyword_upper = b.keyword:upper()
    if store.get_keyword(keyword_upper) or keyword_upper:match("^%*MAT_") then
      local block_lines = {}
      local block_rows = {}
      for r = b.start_row, b.end_row do
        local line = lines[r] or ""
        if not is_comment_line(line) then
          block_lines[#block_lines + 1] = line
          block_rows[#block_rows + 1] = r
        else
          removed = removed + 1
          entries[#entries + 1] = { row = r, line = line, reason = "comment", keyword = keyword_upper }
        end
      end

      while #block_lines > 0 and is_blank_line(block_lines[1] or "") do
        entries[#entries + 1] = { row = block_rows[1], line = block_lines[1], reason = "leading-blank", keyword = keyword_upper }
        table.remove(block_lines, 1)
        table.remove(block_rows, 1)
        removed = removed + 1
      end
      while #block_lines > 0 and is_blank_line(block_lines[#block_lines] or "") do
        entries[#entries + 1] = { row = block_rows[#block_rows], line = block_lines[#block_lines], reason = "trailing-blank", keyword = keyword_upper }
        table.remove(block_lines, #block_lines)
        table.remove(block_rows, #block_rows)
        removed = removed + 1
      end

      -- Normalize keyword line to uppercase
      if #block_lines > 0 then
        block_lines[1] = block_lines[1]:gsub(vim.pesc(b.keyword), keyword_upper)
      end

      for _, line in ipairs(block_lines) do
        out[#out + 1] = line
      end
    else
      entries[#entries + 1] = {
        row = b.start_row,
        line = lines[b.start_row] or "",
        reason = "unknown-block",
        keyword = b.keyword,
        count = b.end_row - b.start_row + 1,
      }
      removed = removed + (b.end_row - b.start_row + 1)
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  return removed, entries
end

-- Align parameter definition lines: equals signs first, then values, then comments/descriptions
-- Step 1: Align = signs (lhs right-aligned, " = " with one space on each side)
-- Step 2: Align values and subsequent content (descriptions or comments)
local function align_parameter_definitions_comprehensive(block_lines)
  local specs = {}
  local max_lhs = 0
  local max_value = 0
  local has_comment = false
  local has_desc = false

  for i, line in ipairs(block_lines or {}) do
    local indent, lhs, rest = line:match("^(%s*)(%%?[%a_][%w_]*)%s*=%s*(.-)%s*$")
    if lhs and rest ~= "" then
      -- Try to find comment (#) first
      local hash_pos = rest:find("#")
      local value, comment = nil, nil
      if hash_pos then
        value = trim(rest:sub(1, hash_pos - 1))
        comment = rest:sub(hash_pos)
        has_comment = true
      else
        value = trim(rest)
        comment = nil
      end

      -- Try to find description (comma-quoted) if no comment
      local desc = nil
      if not comment then
        local desc_start = nil
        -- First try: quoted string followed by more fields (e.g. ,"desc",extra)
        for pos = #rest - 1, 1, -1 do
          if rest:sub(pos):match('^,%s*"[^"]*"%s*,') then
            desc_start = pos
            break
          end
        end
        -- Second try: quoted string at end of line
        if not desc_start then
          for pos = #rest - 1, 1, -1 do
            if rest:sub(pos):match('^,%s*"[^"]*"%s*$') then
              desc_start = pos
              break
            end
          end
        end
        if desc_start then
          value = trim(rest:sub(1, desc_start - 1))
          desc = trim(rest:sub(desc_start + 1))
          has_desc = true
        end
      end

      if value ~= "" then
        specs[i] = {
          indent = indent or "",
          lhs = lhs,
          value = value,
          comment = comment,
          desc = desc,
          line = line,
        }
        max_lhs = math.max(max_lhs, #lhs)
        max_value = math.max(max_value, #value)
      end
    end
  end

  if max_lhs == 0 then
    return block_lines
  end

  -- Calculate alignment columns
  -- Step 1: Parameter names are flush-left (indent + name), padded on right to align equals signs
  -- Step 2: Values aligned after " = "
  -- Step 3: Comments aligned after longest value + 2 spaces
  -- Step 4: Descriptions (quoted strings) aligned so the opening double-quote starts on the same column

  -- Pre-compute max prefix length for lines that have a quoted description,
  -- so we can align the opening double-quote across all such lines.
  -- The comma is followed by exactly 3 spaces before the double-quote.
  local max_desc_prefix_len = 0
  for i, spec in pairs(specs) do
    if spec.desc then
      local rhs_pad = string.rep(" ", max_lhs - #spec.lhs)
      local value_pad = string.rep(" ", max_value - #spec.value)
      local prefix = spec.indent .. spec.lhs .. rhs_pad .. " = " .. spec.value .. value_pad .. ",   "
      max_desc_prefix_len = math.max(max_desc_prefix_len, #prefix)
    end
  end

  local out = {}
  for i, line in ipairs(block_lines or {}) do
    local spec = specs[i]
    if not spec then
      out[#out + 1] = line
    else
      -- Step 1: Align equals sign (pad name on the RIGHT, not left)
      local rhs_pad = string.rep(" ", max_lhs - #spec.lhs)
      local text = spec.indent .. spec.lhs .. rhs_pad .. " = "

      -- Step 2: Add value with alignment for subsequent content
      local value_pad = ""
      if spec.comment or spec.desc then
        -- If there's comment or desc, right-pad the value so they align
        value_pad = string.rep(" ", max_value - #spec.value)
      end
      text = text .. spec.value .. value_pad

      -- Step 3: Add comment or description with spacing
      if spec.comment then
        text = text .. "  " .. spec.comment
      elseif spec.desc then
        -- Align the opening double-quote by padding after the comma (fixed 3 spaces)
        local prefix = text .. ",   "
        local extra_pad = string.rep(" ", max_desc_prefix_len - #prefix)
        -- Normalize spaces after commas in the desc part (keep commas inside quotes untouched)
        local function normalize_desc_commas(s)
          local out = {}
          local in_quote = false
          local i = 1
          while i <= #s do
            local c = s:sub(i, i)
            if c == '"' then
              in_quote = not in_quote
              out[#out + 1] = c
            elseif c == ',' and not in_quote then
              out[#out + 1] = c
              while i + 1 <= #s and s:sub(i + 1, i + 1) == ' ' do
                i = i + 1
              end
              out[#out + 1] = ' '
            else
              out[#out + 1] = c
            end
            i = i + 1
          end
          return table.concat(out)
        end
        text = prefix .. extra_pad .. normalize_desc_commas(spec.desc)
      end

      out[#out + 1] = text
    end
  end

  return out
end

local function split_csv_keep_empty(line)
  local out = {}
  local s = (line or "") .. ","
  for part in s:gmatch("(.-),") do
    out[#out + 1] = part
  end
  return out
end

local function format_curve_data_lines(block_lines)
  -- Align multi-column data rows.
  -- Signed numbers (+/-) are split into a sign column and a numeric column,
  -- so digits align regardless of sign presence.
  local data_specs = {}
  local max_widths = {}       -- max numeric width per column
  local column_has_sign = {}  -- true if any field in this column has a leading sign

  for i, line in ipairs(block_lines) do
    if (line or ""):find(",") then
      local fields = split_csv_keep_empty(line)
      if #fields >= 2 then
        local cols = {}
        local signs = {}
        local num_parts = {}
        local has_content = false
        for ci = 1, #fields do
          local c = trim(fields[ci])
          cols[ci] = c
          if c ~= "" then
            has_content = true
            if c:match("^[+-]%d") or c:match("^[+-]%.%d") then
              signs[ci] = c:sub(1, 1)
              num_parts[ci] = c:sub(2)
              column_has_sign[ci] = true
            else
              signs[ci] = ""
              num_parts[ci] = c
            end
          end
        end
        if has_content then
          local widths = {}
          for ci = 1, #cols do
            local w = vim.fn.strdisplaywidth(num_parts[ci] or "")
            widths[ci] = w
            max_widths[ci] = math.max(max_widths[ci] or 0, w)
          end
          data_specs[i] = { cols = cols, signs = signs, num_parts = num_parts, widths = widths }
        end
      end
    end
  end

  if not next(max_widths) then
    return block_lines
  end

  local function format_field(ci, spec)
    local sign = spec.signs[ci] or ""
    local num = spec.num_parts[ci] or spec.cols[ci] or ""
    if column_has_sign[ci] then
      return (sign ~= "" and sign or " ") .. num
    end
    return num
  end

  local out = {}
  for i, line in ipairs(block_lines) do
    local spec = data_specs[i]
    if not spec then
      out[#out + 1] = line
    else
      local text = format_field(1, spec)
      local total_w_1 = column_has_sign[1] and (1 + (spec.widths[1] or 0)) or (spec.widths[1] or 0)
      for ci = 2, #spec.cols do
        local prev_max = max_widths[ci - 1] or 0
        local prev_total = column_has_sign[ci - 1] and (1 + prev_max) or prev_max
        local prev_w = spec.widths[ci - 1] or 0
        local prev_total_w = column_has_sign[ci - 1] and (1 + prev_w) or prev_w
        local pad = string.rep(" ", math.max(0, prev_total - prev_total_w))
        text = text .. ", " .. pad .. format_field(ci, spec)
      end
      out[#out + 1] = text
    end
  end
  return out
end

local function normalize_comma_lines(block_lines)
  local out = {}
  for _, line in ipairs(block_lines or {}) do
    local t = trim(line)
    if t == "" or t:sub(1, 1) == "#" or t:sub(1, 1) == "$" then
      out[#out + 1] = line
    else
      local fields = split_csv_keep_empty(line)
      if #fields > 1 then
        local lead = line:match("^(%s*)") or ""
        local text = trim(fields[1])
        for i = 2, #fields do
          text = text .. ", " .. trim(fields[i])
        end
        -- If first field was empty: ensure exactly one space before the
        -- leading comma; discard the original lead to avoid stacking spaces.
        if trim(fields[1]) == "" then
          out[#out + 1] = " " .. text
        else
          out[#out + 1] = lead .. text
        end
      else
        out[#out + 1] = line
      end
    end
  end
  return out
end

local function normalize_expression_lines(block_lines)
  local out = {}
  for _, line in ipairs(block_lines or {}) do
    local t = trim(line)
    if t == "" or t:sub(1, 1) == "#" or t:sub(1, 1) == "$" then
      out[#out + 1] = line
    else
      local lead = line:match("^(%s*)") or ""
      -- Step 1: remove spaces around ^
      local text = t:gsub("%s*%^%s*", "^")
      -- Step 2: remove spaces around + - * /
      -- Protect quoted strings
      local parts = {}
      local qi = 1
      while true do
        local qs, qe = text:find('"', qi)
        if not qs then
          parts[#parts + 1] = { type = "text", value = text:sub(qi) }
          break
        end
        parts[#parts + 1] = { type = "text", value = text:sub(qi, qs - 1) }
        local qe2 = text:find('"', qe + 1)
        if not qe2 then
          parts[#parts + 1] = { type = "quote", value = text:sub(qs) }
          break
        end
        parts[#parts + 1] = { type = "quote", value = text:sub(qs, qe2) }
        qi = qe2 + 1
      end
      for _, p in ipairs(parts) do
        if p.type == "text" then
          local v = p.value
          -- Remove spaces around + * / (always binary operators)
          v = v:gsub("%s*([%+%*/])%s*", "%1")
          -- For minus: only remove spaces around binary subtraction
          -- (both sides must be identifier chars). Preserve space before
          -- unary minus like ", -0.5" or "( -1".
          v = v:gsub("([%w_%%])%s*%-%s*([%w_%%])", "%1-%2")
          p.value = v
        end
      end
      local result = ""
      for _, p in ipairs(parts) do
        result = result .. p.value
      end
      out[#out + 1] = lead .. result
    end
  end
  return out
end

-- Format ~repeat / ~end_repeat indentation.
-- ~repeat and ~end_repeat are indented by (depth * 2) spaces.
-- Content lines inside repeat blocks are indented by (depth * 2) spaces.
-- Lines outside repeat blocks are left untouched.
local function format_repeat_indent(lines)
  local out = {}
  local depth = 0
  for _, line in ipairs(lines) do
    local t = trim(line)
    if t:match("^~repeat") then
      out[#out + 1] = string.rep(" ", depth * 2) .. t
      depth = depth + 1
    elseif t:match("^~end_repeat") then
      depth = math.max(0, depth - 1)
      out[#out + 1] = string.rep(" ", depth * 2) .. t
    else
      if depth > 0 then
        out[#out + 1] = string.rep(" ", depth * 2) .. t
      else
        out[#out + 1] = line
      end
    end
  end
  return out
end

local function simple_beautify_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = split_keyword_blocks(lines)
  if #blocks == 0 then
    return 0, {}
  end

  local changed = 0
  local entries = {}

  for _, b in ipairs(blocks) do
    local kw_upper = b.keyword:upper()
    local block_lines = {}
    for r = b.start_row + 1, b.end_row do
      block_lines[#block_lines + 1] = lines[r] or ""
    end

    local formatted = nil
    if kw_upper == "*PARAMETER" or kw_upper == "*PARAMETER_DEFAULT" then
      -- 规范化表达式运算符，然后对齐参数定义
      formatted = normalize_expression_lines(block_lines)
      formatted = align_parameter_definitions_comprehensive(formatted)
    elseif kw_upper == "*CURVE" or kw_upper == "*TABLE" or kw_upper == "*PATH"
        or kw_upper == "*NODE" or kw_upper:match("^%*ELEMENT") then
      -- 列对齐优先：不对齐后再用 normalize_comma_lines 破坏列宽
      formatted = format_curve_data_lines(block_lines)
    elseif kw_upper == "*FUNCTION" then
      -- 表达式规范化（逗号在函数调用括号内，不能用简单 CSV split 处理）
      formatted = normalize_expression_lines(block_lines)
    else
      -- 其他一般关键字：逗号后一个空格 + 表达式运算符规范化
      formatted = normalize_comma_lines(block_lines)
      formatted = normalize_expression_lines(formatted)
    end

    if formatted then
      for idx, new_line in ipairs(formatted) do
        local row = b.start_row + idx
        local old_line = lines[row]
        if old_line ~= new_line then
          lines[row] = new_line
          changed = changed + 1
          entries[#entries + 1] = { row = row, keyword = b.keyword, old_line = old_line, new_line = new_line }
        end
      end
    end
  end

  -- Format ~repeat / ~end_repeat indentation
  local new_lines = format_repeat_indent(lines)
  for i, new_line in ipairs(new_lines) do
    if lines[i] ~= new_line then
      if lines[i] ~= nil or new_line ~= "" then
        changed = changed + 1
        entries[#entries + 1] = { row = i - 1, keyword = "", old_line = lines[i], new_line = new_line }
      end
    end
  end
  lines = new_lines

  if changed > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  return changed, entries
end

local function align_parameter_blocks_in_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = split_keyword_blocks(lines)
  if #blocks == 0 then
    return 0, {}
  end

  local changed = 0
  local entries = {}
  for _, b in ipairs(blocks) do
    local kw_upper = b.keyword:upper()
    local block_lines = {}
    for r = b.start_row + 1, b.end_row do
      block_lines[#block_lines + 1] = lines[r] or ""
    end

    local formatted = nil
    if b.keyword == "*PARAMETER" or b.keyword == "*PARAMETER_DEFAULT" then
      formatted = align_parameter_definitions_comprehensive(block_lines)
    elseif kw_upper == "*OBJECT" then
      local param_start = nil
      for li, line in ipairs(block_lines) do
        if line:match("^%s*%%?[%a_][%w_]+%s*=") then
          param_start = li
          break
        end
      end
      if param_start then
        local param_lines = {}
        for li = param_start, #block_lines do
          param_lines[#param_lines + 1] = block_lines[li]
        end
        local formatted_params = align_parameter_definitions_comprehensive(param_lines)
        formatted = {}
        for li = 1, param_start - 1 do
          formatted[li] = block_lines[li]
        end
        for li, l in ipairs(formatted_params) do
          formatted[param_start + li - 1] = l
        end
      end
    elseif kw_upper == "*CURVE" or kw_upper == "*TABLE" or kw_upper == "*PATH" then
      formatted = format_curve_data_lines(block_lines)
    end

    if formatted then
      for idx, new_line in ipairs(formatted) do
        local row = b.start_row + idx
        local old_line = lines[row]
        if old_line ~= new_line then
          lines[row] = new_line
          changed = changed + 1
          entries[#entries + 1] = {
            row = row,
            keyword = b.keyword,
            old_line = old_line,
            new_line = new_line,
          }
        end
      end
    end
  end

  if changed > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  return changed, entries
end

return {
  clean_current_buffer = clean_current_buffer,
  advanced_clear_current_buffer = advanced_clear_current_buffer,
  simple_beautify_buffer = simple_beautify_buffer,
  align_parameter_blocks_in_buffer = align_parameter_blocks_in_buffer,
  align_parameter_definitions_comprehensive = align_parameter_definitions_comprehensive,
}
