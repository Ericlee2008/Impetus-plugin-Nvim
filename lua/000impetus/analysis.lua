local store = require("impetus.store")

local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_number_prefix(line)
  return (line:gsub("^%s*%d+%.%s*", ""))
end

local function parse_keyword(line)
  local normalized = trim(strip_number_prefix(line or ""))
  return normalized:match("^(%*[%w_%-]+)")
end

local function is_control_directive_line(line)
  local normalized = trim(strip_number_prefix(line or ""))
  return normalized:match("^~if%f[%A]")
    or normalized:match("^~else_if%f[%A]")
    or normalized:match("^~else%f[%A]")
    or normalized:match("^~end_if%f[%A]")
    or normalized:match("^~repeat%f[%A]")
    or normalized:match("^~end_repeat%f[%A]")
    or normalized:match("^~convert_from_[%w_%-]*")
    or normalized:match("^~end_convert%f[%A]")
end

local function is_title_line(line)
  local normalized = trim(strip_number_prefix(line or ""))
  return normalized == '"Optional title"' or normalized:match('^".*"$')
end

local function is_meta_line(line)
  local normalized = trim(strip_number_prefix(line or ""))
  if normalized == "" then
    return true
  end
  if normalized:sub(1, 1) == "#" or normalized:sub(1, 1) == "~" then
    return true
  end
  if normalized:sub(1, 1) == "$" then
    return true
  end
  if normalized:match("^%-+$") then
    return true
  end
  if normalized == "Variable         Description" then
    return true
  end
  if is_title_line(normalized) then
    return true
  end
  return false
end

local function split_csv_outside_quotes(line)
  local out = {}
  local in_quotes = false
  local start_pos = 1
  local i = 1
  local function emit(end_pos)
    local seg = line:sub(start_pos, end_pos)
    out[#out + 1] = trim(seg)
  end
  while i <= #line do
    local ch = line:sub(i, i)
    if ch == '"' then
      in_quotes = not in_quotes
    elseif ch == "," and not in_quotes then
      emit(i - 1)
      start_pos = i + 1
    end
    i = i + 1
  end
  emit(#line)
  return out
end

local function normalize_param_name(s)
  return (trim(s or ""):gsub("^%%", ""):gsub("^%[", ""):gsub("%]$", "")):lower()
end

local function value_as_id(v)
  local n = trim(v or "")
  if n == "" then
    return nil
  end
  if n:match("^[-+]?%d+$") then
    return n
  end
  return nil
end

local function classify_def_type(keyword, param_name)
  local p = normalize_param_name(param_name)
  local k = (keyword or ""):upper()
  if p:match("^pid") or p == "partid" or p == "part_id" then
    return "part"
  end
  if p:match("^mid") then
    return "material"
  end
  if p:match("^fid") then
    return "function"
  end
  if p:match("^gid") then
    return "geometry"
  end
  if p:match("^ctid") or p:match("^coid") or p:match("^bcid") then
    return "command"
  end
  if k:match("^%*PART") and (p == "id" or p == "typeid") then
    return "part"
  end
  return nil
end

local function classify_ref_type(keyword, param_name)
  local p = normalize_param_name(param_name)
  local k = (keyword or ""):upper()
  if p == "typeid" then
    if k:match("^%*BC") then
      return "part"
    end
  end
  if p:match("^pid") or p == "partid" or p == "part_id" then
    return "part"
  end
  if p:match("^mid") then
    return "material"
  end
  if p:match("^fid") then
    return "function"
  end
  if p:match("^gid") then
    return "geometry"
  end
  return nil
end

local function find_keyword_block(lines, row)
  local start_row = nil
  local keyword = nil
  for r = row, 1, -1 do
    if is_control_directive_line(lines[r] or "") then
      break
    end
    local kw = parse_keyword(lines[r] or "")
    if kw then
      start_row = r
      keyword = kw
      break
    end
  end
  if not start_row then
    return nil
  end
  local end_row = #lines
  for r = start_row + 1, #lines do
    if parse_keyword(lines[r] or "") or is_control_directive_line(lines[r] or "") then
      end_row = r - 1
      break
    end
  end
  return { keyword = keyword, start_row = start_row, end_row = end_row }
end

local function collect_data_rows(lines, block)
  local rows = {}
  local saw_non_title = false
  for r = block.start_row + 1, block.end_row do
    local line = lines[r] or ""
    if not is_meta_line(line) then
      if block.keyword == "*BC_MOTION" and not saw_non_title then
        local values = split_csv_outside_quotes(line)
        local first = trim(values[1] or "")
        if first ~= "" and not first:match('^".*"$') then
          saw_non_title = true
          if not (first:match("^[+-]?%d+$")
            or first:match("^[+-]?%d+%.0+$")
            or first:match("^%%[%w_]+$")
            or first:match("^%[%%[%w_]+%]$")) then
            rows[#rows + 1] = r
            goto continue
          end
        end
      end
      rows[#rows + 1] = r
      saw_non_title = true
    end
    ::continue::
  end
  return rows
end

local function field_index_from_col(line, col1)
  local trimmed_col = math.max(1, col1)
  local n = #line
  while trimmed_col <= n and line:sub(trimmed_col, trimmed_col):match("%s") do
    trimmed_col = trimmed_col + 1
  end
  local in_quotes = false
  local idx = 1
  local seg_start = 1
  local i = 1
  while i <= #line do
    local ch = line:sub(i, i)
    if ch == '"' then
      in_quotes = not in_quotes
    elseif ch == "," and not in_quotes then
      if trimmed_col >= seg_start and trimmed_col <= i then
        return idx
      end
      idx = idx + 1
      seg_start = i + 1
    end
    i = i + 1
  end
  if trimmed_col >= seg_start and trimmed_col <= (#line + 1) then
    return idx
  end
  return nil
end

local function bc_motion_omits_bcid(data_rows, lines)
  local first_row = data_rows and data_rows[1]
  if not first_row then
    return false
  end
  local values = split_csv_outside_quotes(lines[first_row] or "")
  local first = trim(values[1] or "")
  if first == "" or first:match('^".*"$') then
    return false
  end
  return not (
    first:match("^[+-]?%d+$")
    or first:match("^[+-]?%d+%.0+$")
    or first:match("^%%[%w_]+$")
    or first:match("^%[%%[%w_]+%]$")
  )
end

local function schema_row_for_context(keyword, data_rows, lines, data_row_index)
  local kw = (keyword or ""):upper()
  if kw == "*BC_MOTION" and bc_motion_omits_bcid(data_rows, lines) then
    return data_row_index + 1
  end
  return data_row_index
end

function M.build_buffer_index(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local db = store.get_db()

  local idx = {
    params = {
      defs = {},
      refs = {},
    },
    objects = {
      part = {},
      material = {},
      ["function"] = {},
      geometry = {},
      command = {},
    },
    keywords = {},
  }

  for i, raw in ipairs(lines) do
    local kw = parse_keyword(raw or "")
    if kw then
      idx.keywords[#idx.keywords + 1] = { keyword = kw, row = i }
    end
    for p in (raw or ""):gmatch("%%([%a_][%w_]*)") do
      local key = normalize_param_name(p)
      idx.params.refs[key] = idx.params.refs[key] or {}
      idx.params.refs[key][#idx.params.refs[key] + 1] = { row = i, col = (raw:find("%%" .. p, 1, true) or 1) - 1, line = raw }
    end
    local def_name = raw:match("^%s*%%?([%a_][%w_]*)%s*=")
    if def_name then
      local key = normalize_param_name(def_name)
      idx.params.defs[key] = idx.params.defs[key] or {}
      local c = (raw:find("%%" .. def_name, 1, true) or raw:find(def_name, 1, true) or 1) - 1
      idx.params.defs[key][#idx.params.defs[key] + 1] = { row = i, col = c, line = raw }
    end
  end

  for i = 1, #lines do
    local block = find_keyword_block(lines, i)
    if block then
      local entry = db[block.keyword]
      local data_rows = collect_data_rows(lines, block)
      for row_idx, row in ipairs(data_rows) do
        local values = split_csv_outside_quotes(lines[row] or "")
        local schema = (entry and entry.signature_rows and (entry.signature_rows[row_idx] or entry.signature_rows[#entry.signature_rows])) or {}
        for field_idx, value in ipairs(values) do
          local param_name = schema[field_idx]
          if param_name then
            local t = classify_def_type(block.keyword, param_name)
            local idv = value_as_id(value)
            if t and idv then
              idx.objects[t][idv] = true
            end
          end
        end
      end
      i = block.end_row
    end
  end

  return idx
end

function M.current_context(bufnr, row, col0)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  row = row or vim.api.nvim_win_get_cursor(0)[1]
  col0 = col0 or vim.api.nvim_win_get_cursor(0)[2]
  local block = find_keyword_block(lines, row)
  if not block then
    return nil
  end
  local entry = store.get_db()[block.keyword]
  if not entry then
    return { keyword = block.keyword }
  end
  local data_rows = collect_data_rows(lines, block)
  local row_idx = nil
  for i, r in ipairs(data_rows) do
    if r == row then
      row_idx = i
      break
    end
  end
  if not row_idx then
    return { keyword = block.keyword }
  end
  local schema_row_idx = schema_row_for_context(block.keyword, data_rows, lines, row_idx)
  local schema = entry.signature_rows and (entry.signature_rows[schema_row_idx] or entry.signature_rows[#entry.signature_rows]) or nil
  if not schema then
    return { keyword = block.keyword }
  end
  local field_idx = field_index_from_col(lines[row] or "", col0 + 1)
  local param_name = field_idx and schema[field_idx] or nil
  return {
    keyword = block.keyword,
    row_idx = schema_row_idx,
    field_idx = field_idx,
    param_name = param_name,
  }
end

function M.suggest_object_values(bufnr, ctx, base)
  local out = {}
  if not ctx or not ctx.keyword or not ctx.param_name then
    return out
  end
  local t = classify_ref_type(ctx.keyword, ctx.param_name)
  if not t then
    return out
  end
  local idx = M.build_buffer_index(bufnr)
  local pool = idx.objects[t] or {}
  local base_norm = trim(base or "")
  for id, _ in pairs(pool) do
    if base_norm == "" or id:find(base_norm, 1, true) then
      out[#out + 1] = id
    end
  end
  table.sort(out, function(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then
      return na < nb
    end
    return a < b
  end)
  return out
end

function M.param_references(bufnr, name)
  local idx = M.build_buffer_index(bufnr)
  local key = normalize_param_name(name or "")
  return {
    defs = idx.params.defs[key] or {},
    refs = idx.params.refs[key] or {},
  }
end

return M
