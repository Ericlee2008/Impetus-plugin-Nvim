local store = require("impetus.store")

local M = {}
local index_cache = {}

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

local function uncomment_one_level(line)
  local l = line or ""
  l = l:gsub("^%s*#%s?", "", 1)
  l = l:gsub("^%s*%$%s?", "", 1)
  return l
end

local function normalize_token(s)
  return trim((s or ""):lower()):gsub("%s+", "")
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
  -- Only *PART/* keywords define parts
  if k:match("^%*PART") and (p == "id" or p == "typeid" or p:match("^pid") or p == "partid" or p == "part_id") then
    return "part"
  end
  -- Only *MAT_* keywords define materials
  if k:match("^%*MAT_") and (p == "mid" or p == "id") then
    return "material"
  end
  -- Only *CURVE defines curves via cid/id
  if k == "*CURVE" and (p == "cid" or p == "id") then
    return "curve"
  end
  -- Only *FUNCTION defines curves/functions via fid/id
  if k == "*FUNCTION" and (p == "fid" or p == "id") then
    return "curve"
  end
  -- Only *GEOMETRY_* keywords define geometry
  if k:match("^%*GEOMETRY") and (p == "gid" or p == "id") then
    return "geometry"
  end
  -- Damage property commands define prop_damage
  if k == "*PROP_DAMAGE_CL" and (p == "id" or p == "did") then
    return "prop_damage"
  end
  -- Thermal property commands define prop_thermal
  if k == "*PROP_THERMAL" and (p == "id" or p == "thpid") then
    return "prop_thermal"
  end
  -- Equation-of-state keywords define eos
  if k:match("^%*EOS") and (p == "id" or p == "eosid") then
    return "eos"
  end
  if p:match("^ctid") or p:match("^coid") or p:match("^bcid") then
    return "command"
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
  if p:match("^fid") or p:match("^cid") then
    return "curve"
  end
  if p:match("^gid") then
    return "geometry"
  end
  if p == "did" then
    return "prop_damage"
  end
  if p == "thpid" then
    return "prop_thermal"
  end
  if p == "eosid" then
    return "eos"
  end
  return nil
end

local entype_to_obj_type = {
  P = "part", RB = "part", SPH = "part", DP = "part",
  PS = "part_set",
  N = "node",
  NS = "node_set",
  E = "element",
  ES = "element_set",
  G = "geometry",
  GS = "geometry_set",
  FS = "face_set",
  M = "material",
}

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

local function field_col_from_idx(line, target_idx)
  local idx = 1
  local seg_start = 1
  local i = 1
  while i <= #line do
    local ch = line:sub(i, i)
    if ch == "," then
      if idx == target_idx then
        local s = seg_start
        while s < i and line:sub(s, s):match("%s") do s = s + 1 end
        return s - 1  -- 0-indexed
      end
      idx = idx + 1
      seg_start = i + 1
    end
    i = i + 1
  end
  if idx == target_idx then
    local s = seg_start
    while s <= #line and line:sub(s, s):match("%s") do s = s + 1 end
    return s - 1  -- 0-indexed
  end
  return 0
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

local function build_params_from_lines(lines)
  local params = { defs = {}, refs = {} }
  for i, raw in ipairs(lines or {}) do
    for p in (raw or ""):gmatch("%%([%a_][%w_]*)") do
      local key = normalize_param_name(p)
      params.refs[key] = params.refs[key] or {}
      params.refs[key][#params.refs[key] + 1] = {
        row = i,
        col = (raw:find("%" .. p, 1, true) or 1) - 1,
        line = raw,
      }
    end
    local def_name = (raw or ""):match("^%s*%%?([%a_][%w_]*)%s*=")
    if def_name then
      local key = normalize_param_name(def_name)
      params.defs[key] = params.defs[key] or {}
      local c = (raw:find("%" .. def_name, 1, true) or raw:find(def_name, 1, true) or 1) - 1
      params.defs[key][#params.defs[key] + 1] = { row = i, col = c, line = raw }
    end
  end
  return params
end

local function collect_include_paths(bufnr, lines)
  local buf_file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
  local dir = vim.fn.fnamemodify(buf_file, ":h")
  local paths = {}
  local seen = {}
  local in_include = false
  for _, raw in ipairs(lines or {}) do
    local kw = parse_keyword(raw)
    if kw then
      in_include = (kw:upper() == "*INCLUDE")
    elseif in_include then
      local t = trim(strip_number_prefix(raw or ""))
      if t ~= "" and not t:match("^[#$]") then
        local path = t:match('"(.-)"') or trim(t:match("^([^,]+)") or "")
        if path and path ~= "" then
          if not path:match("^[A-Za-z]:") and not path:match("^[/\\]") then
            path = dir .. "/" .. path
          end
          local abs = vim.fn.fnamemodify(path, ":p")
          if not seen[abs] then
            seen[abs] = true
            paths[#paths + 1] = abs
          end
        end
        in_include = false
      end
    end
  end
  return paths
end

function M.build_buffer_index(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = index_cache[bufnr]
  if cached and cached.changedtick == changedtick and cached.index then
    return cached.index
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local db = store.get_db()

  local idx = {
    params = {
      defs = {},
      refs = {},
    },
    objects = {
      part = {}, material = {}, ["function"] = {}, geometry = {}, command = {}, curve = {},
      part_set = {}, node_set = {}, element_set = {}, geometry_set = {}, face_set = {}, set = {},
      prop_damage = {}, prop_thermal = {}, eos = {},
    },
    object_defs = {
      part = {}, material = {}, ["function"] = {}, geometry = {}, command = {}, curve = {},
      part_set = {}, node_set = {}, element_set = {}, geometry_set = {}, face_set = {}, set = {},
      prop_damage = {}, prop_thermal = {}, eos = {},
    },
    object_refs = {
      part = {}, material = {}, ["function"] = {}, geometry = {}, command = {}, curve = {},
      part_set = {}, node_set = {}, element_set = {}, geometry_set = {}, face_set = {}, set = {},
      prop_damage = {}, prop_thermal = {}, eos = {},
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
      idx.params.refs[key][#idx.params.refs[key] + 1] = { row = i, col = (raw:find("%" .. p, 1, true) or 1) - 1, line = raw }
    end
    local def_name = raw:match("^%s*%%?([%a_][%w_]*)%s*=")
    if def_name then
      local key = normalize_param_name(def_name)
      idx.params.defs[key] = idx.params.defs[key] or {}
      local c = (raw:find("%" .. def_name, 1, true) or raw:find(def_name, 1, true) or 1) - 1
      idx.params.defs[key][#idx.params.defs[key] + 1] = { row = i, col = c, line = raw }
    end
  end

  for i = 1, #lines do
    local block = find_keyword_block(lines, i)
    if block and block.start_row == i then
      local entry = db[block.keyword]
      local data_rows = collect_data_rows(lines, block)
      local kw_upper = (block.keyword or ""):upper()
      for row_idx, row in ipairs(data_rows) do
        local values = split_csv_outside_quotes(lines[row] or "")
        local schema = (entry and entry.signature_rows and (entry.signature_rows[row_idx] or entry.signature_rows[#entry.signature_rows])) or {}
        local raw_line = lines[row] or ""
        local function store_def(t, idv, col)
          if not t or not idv then return end
          idx.objects[t][idv] = true
          if not idx.object_defs[t][idv] then
            idx.object_defs[t][idv] = { row = row, col = col or 0, keyword = block.keyword, line = raw_line }
          end
        end
        local function store_ref(t, idv, col)
          if not t or not idv then return end
          idx.object_refs[t][idv] = idx.object_refs[t][idv] or {}
          local list = idx.object_refs[t][idv]
          list[#list + 1] = { row = row, col = col or 0, keyword = block.keyword, line = raw_line }
        end
        -- Hardcoded definitions
        if kw_upper == "*PART" and row_idx == 1 then
          store_def("part", value_as_id(values[1]), field_col_from_idx(raw_line, 1))
        end
        if kw_upper:match("^%*SET_") and row_idx == 1 then
          local set_t = "set"
          if kw_upper:match("^%*SET_PART") then set_t = "part_set"
          elseif kw_upper:match("^%*SET_NODE") then set_t = "node_set"
          elseif kw_upper:match("^%*SET_ELEMENT") then set_t = "element_set"
          elseif kw_upper:match("^%*SET_GEOMETRY") then set_t = "geometry_set"
          elseif kw_upper:match("^%*SET_FACE") then set_t = "face_set"
          end
          store_def(set_t, value_as_id(values[1]), field_col_from_idx(raw_line, 1))
        end
        if (kw_upper == "*CURVE" or kw_upper == "*FUNCTION") and row_idx == 1 then
          store_def("curve", value_as_id(values[1]), field_col_from_idx(raw_line, 1))
        end
        if kw_upper == "*PROP_DAMAGE_CL" and row_idx == 1 then
          store_def("prop_damage", value_as_id(values[1]), field_col_from_idx(raw_line, 1))
        end
        if kw_upper == "*PROP_THERMAL" and row_idx == 1 then
          store_def("prop_thermal", value_as_id(values[1]), field_col_from_idx(raw_line, 1))
        end
        if kw_upper:match("^%*EOS") and row_idx == 1 then
          store_def("eos", value_as_id(values[1]), field_col_from_idx(raw_line, 1))
        end
        -- Schema-driven: collect defs and refs from param names
        for field_idx, value in ipairs(values) do
          local param_name = schema[field_idx]
          if param_name then
            local idv = value_as_id(value)
            if idv then
              local def_t = classify_def_type(block.keyword, param_name)
              if def_t then store_def(def_t, idv, field_col_from_idx(raw_line, field_idx)) end
              local ref_t = classify_ref_type(block.keyword, param_name)
              -- For enid* fields, derive type from the preceding entype field's value
              if not ref_t and normalize_param_name(param_name):match("^enid") then
                for i = field_idx - 1, 1, -1 do
                  local v = trim(values[i] or ""):upper()
                  local t = entype_to_obj_type[v]
                  if t then ref_t = t; break end
                  if v ~= "" then break end
                end
              end
              if ref_t then store_ref(ref_t, idv, field_col_from_idx(raw_line, field_idx)) end
            end
          end
        end
      end
      i = block.end_row
    end
  end

  index_cache[bufnr] = {
    changedtick = changedtick,
    index = idx,
  }
  return idx
end

function M.invalidate_buffer_index(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  index_cache[bufnr] = nil
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
    local raw = lines[row] or ""
    if trim(raw):match("^[#$]") then
      local preview = uncomment_one_level(raw)
      local preview_fields = split_csv_outside_quotes(preview)
      local cursor_col = math.max(0, col0 - ((raw:find("[#$]") or 1)))
      local field_idx = field_index_from_col(preview, cursor_col + 1)
      if field_idx then
        local signature_rows = entry.signature_rows or {}
        local preview_first = normalize_token(preview_fields[1] or "")
        for i, sig in ipairs(signature_rows) do
          if normalize_token(sig[1] or "") == preview_first then
            local param_name = sig[field_idx]
            if param_name then
              return {
                keyword = block.keyword,
                row_idx = i,
                field_idx = field_idx,
                param_name = param_name,
              }
            end
          end
        end
      end
    end
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
  if not ctx or not ctx.keyword then
    return out
  end
  local obj_type = ctx.param_name and classify_ref_type(ctx.keyword, ctx.param_name) or nil
  -- SET_* data rows (row 2+): fields are entity IDs matching the set type
  if not obj_type and ctx.row_idx and ctx.row_idx >= 2 then
    local kw = (ctx.keyword or ""):upper()
    if kw:match("^%*SET_PART") then
      obj_type = "part"
    elseif kw:match("^%*SET_GEOMETRY") then
      obj_type = "geometry"
    end
  end
  -- Entype-based fallback: only for anonymous fields or explicit enid_* fields
  -- Skip if field has a named schema parameter (like bc_tr, bc_rot) that isn't an entity ID
  local pn = ctx.param_name and normalize_param_name(ctx.param_name) or nil
  local is_enid_field = not pn or pn:match("^enid")
  if not obj_type and is_enid_field and ctx.field_idx and ctx.field_idx > 1 then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local line = (vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false) or {})[1] or ""
    local fields = split_csv_outside_quotes(line)
    for i = ctx.field_idx - 1, 1, -1 do
      local v = trim(fields[i] or ""):upper()
      local t = entype_to_obj_type[v]
      if t then
        obj_type = t
        break
      end
    end
  end
  if not obj_type then
    return out
  end
  local idx = M.build_buffer_index(bufnr)
  local pool = idx.objects[obj_type] or {}
  for id, _ in pairs(pool) do
    out[#out + 1] = id
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

local obj_def_keywords = {
  ["*CURVE"]    = "curve",
  ["*FUNCTION"] = "curve",
  ["*PART"]     = "part",
  ["*MAT_ELASTIC"]   = "material",
  ["*MAT_PLASTIC"]   = "material",
  ["*MAT_OBJECT"]    = "material",
}
local function obj_type_for_def_keyword(kw)
  local k = (kw or ""):upper()
  if k == "*CURVE" or k == "*FUNCTION" then return "curve" end
  if k == "*PART" or k:match("^%*PART_") then return "part" end
  if k:match("^%*SET_PART") then return "part_set" end
  if k:match("^%*SET_NODE") then return "node_set" end
  if k:match("^%*SET_ELEMENT") then return "element_set" end
  if k:match("^%*SET_GEOMETRY") then return "geometry_set" end
  if k:match("^%*SET_FACE") then return "face_set" end
  if k:match("^%*SET_") then return "set" end
  if k:match("^%*MAT_") then return "material" end
  if k == "*PROP_DAMAGE_CL" then return "prop_damage" end
  if k == "*PROP_THERMAL" then return "prop_thermal" end
  if k:match("^%*EOS") then return "eos" end
  return nil
end

function M.object_def_under_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local col0 = vim.api.nvim_win_get_cursor(0)[2]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local block = find_keyword_block(lines, row)
  if not block then return nil end
  local obj_type = obj_type_for_def_keyword(block.keyword)
  if not obj_type then return nil end
  local data_rows = collect_data_rows(lines, block)
  if not data_rows or #data_rows == 0 then return nil end
  -- Must be on the first data row (where the definition ID lives)
  if row ~= data_rows[1] then return nil end
  -- Must be on field 1 (the ID field, not a reference field like mid/secid)
  local ctx = M.current_context(bufnr, row, col0)
  if not ctx or ctx.field_idx ~= 1 then return nil end
  local first_line = lines[data_rows[1]] or ""
  local fields = split_csv_outside_quotes(first_line)
  local idv = value_as_id(trim(fields[1] or ""))
  if not idv then return nil end
  return { obj_type = obj_type, id = idv }
end

function M.object_under_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local col0 = vim.api.nvim_win_get_cursor(0)[2]
  local ctx = M.current_context(bufnr, row, col0)
  if not ctx or not ctx.field_idx then return nil end
  local line = (vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false) or {})[1] or ""
  local fields = split_csv_outside_quotes(line)
  local idv = value_as_id(trim(fields[ctx.field_idx] or ""))
  if not idv then return nil end
  local obj_type = ctx.param_name and classify_ref_type(ctx.keyword, ctx.param_name) or nil
  if not obj_type and ctx.field_idx > 1 then
    for i = ctx.field_idx - 1, 1, -1 do
      local v = trim(fields[i] or ""):upper()
      local t = entype_to_obj_type[v]
      if t then obj_type = t; break end
    end
  end
  if not obj_type then return nil end
  return { obj_type = obj_type, id = idv }
end

function M.object_definition(bufnr, obj_type, id)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local idx = M.build_buffer_index(bufnr)
  return (idx.object_defs[obj_type] or {})[id]
end

function M.object_references(bufnr, obj_type, id)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local idx = M.build_buffer_index(bufnr)
  return (idx.object_refs[obj_type] or {})[id] or {}
end

function M.param_references(bufnr, name)
  local idx = M.build_buffer_index(bufnr)
  local key = normalize_param_name(name or "")
  return {
    defs = idx.params.defs[key] or {},
    refs = idx.params.refs[key] or {},
  }
end

function M.param_references_all(bufnr, name)
  -- Normalize 0 / nil to the concrete buffer number so index_cache keys are stable
  -- and the "bn ~= bufnr" dedup in the all-buffers loop works correctly.
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local key = normalize_param_name(name or "")
  local all_defs = {}
  local all_refs = {}
  local searched = {}

  -- Forward declarations for mutual recursion
  local search_buf
  local search_file

  search_buf = function(bn)
    if vim.b[bn].impetus_info_buffer == 1
      or vim.b[bn].impetus_help_buffer == 1
      or vim.b[bn].impetus_popup_buffer == 1
    then
      return
    end
    local bfile = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bn), ":p")
    if searched[bfile] then return end
    searched[bfile] = true
    local bidx = M.build_buffer_index(bn)
    for _, d in ipairs(bidx.params.defs[key] or {}) do
      all_defs[#all_defs + 1] = { row = d.row, col = d.col, line = d.line, file = bfile }
    end
    for _, r in ipairs(bidx.params.refs[key] or {}) do
      all_refs[#all_refs + 1] = { row = r.row, col = r.col, line = r.line, file = bfile }
    end
    -- Recurse into include files of this buffer
    local blines = vim.api.nvim_buf_get_lines(bn, 0, -1, false)
    for _, path in ipairs(collect_include_paths(bn, blines)) do
      search_file(path)
    end
  end

  -- Search an include file by absolute path (may not be a loaded buffer).
  -- For loaded buffers: delegate to search_buf so it handles the searched[] mark.
  -- Only mark path here for the "read from disk" case (search_buf won't be called).
  search_file = function(path)
    local inc_bufnr = vim.fn.bufnr(path)
    if inc_bufnr > 0 and vim.api.nvim_buf_is_loaded(inc_bufnr) then
      search_buf(inc_bufnr)  -- search_buf owns the searched[] mark for loaded buffers
      return
    end
    if searched[path] then return end
    searched[path] = true
    local ok, result = pcall(function()
      local f = io.open(path, "r")
      if not f then return nil end
      local ls = {}
      for l in f:lines() do ls[#ls + 1] = l end
      f:close()
      return ls
    end)
    local inc_lines = ok and result or nil
    if inc_lines then
      local params = build_params_from_lines(inc_lines)
      for _, d in ipairs(params.defs[key] or {}) do
        all_defs[#all_defs + 1] = { row = d.row, col = d.col, line = d.line, file = path }
      end
      for _, r in ipairs(params.refs[key] or {}) do
        all_refs[#all_refs + 1] = { row = r.row, col = r.col, line = r.line, file = path }
      end
    end
  end

  -- Start with current buffer
  search_buf(bufnr)

  -- Also search all other open impetus/kwt buffers (covers parent files and siblings).
  -- Skip virtual/display buffers (info pane, help pane, popups) — their content is
  -- synthetic and would produce spurious references.
  for _, bn in ipairs(vim.api.nvim_list_bufs()) do
    if bn ~= bufnr and vim.api.nvim_buf_is_loaded(bn) then
      local ft = vim.bo[bn].filetype
      if ft == "impetus" or ft == "kwt" then
        if vim.b[bn].impetus_info_buffer ~= 1
          and vim.b[bn].impetus_help_buffer ~= 1
          and vim.b[bn].impetus_popup_buffer ~= 1
          and vim.b[bn].impetus_child_buffer ~= 1
        then
          search_buf(bn)
        end
      end
    end
  end

  return { defs = all_defs, refs = all_refs }
end

return M
