local M = {}
local subtree_cache = {}
local current_buffer_graph_cache = {}
local file_graph_cache = {}

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_number_prefix(line)
  return ((line or ""):gsub("^%s*%d+%.%s*", ""))
end

local function parse_keyword(line)
  local normalized = trim(strip_number_prefix(line or ""))
  return normalized:match("^(%*[%w_%-]+)")
end

local function is_control_line(line)
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

local function is_comment_or_blank(line)
  local normalized = trim(strip_number_prefix(line or ""))
  return normalized == ""
    or normalized:sub(1, 1) == "#"
    or normalized:sub(1, 1) == "$"
end

local function is_title_line(line)
  local normalized = trim(strip_number_prefix(line or ""))
  return normalized == '"Optional title"' or normalized:match('^".*"$')
end

local function split_csv_outside_quotes(line)
  local out = {}
  local in_quotes = false
  local start_pos = 1
  local i = 1

  local function emit(end_pos)
    out[#out + 1] = trim((line or ""):sub(start_pos, end_pos))
  end

  while i <= #(line or "") do
    local ch = line:sub(i, i)
    if ch == '"' then
      in_quotes = not in_quotes
    elseif ch == "," and not in_quotes then
      emit(i - 1)
      start_pos = i + 1
    end
    i = i + 1
  end
  emit(#(line or ""))
  return out
end

local function integer_like(value)
  local v = trim(value or "")
  if v == "" then
    return false
  end
  return v:match("^[+-]?%d+$")
    or v:match("^[+-]?%d+%.0+$")
    or v:match("^[+-]?%d+[eE][+-]?0+$")
    or v:match("^%%[%w_]+$")
    or v:match("^%[%%[%w_]+%]$")
end

local function range_members(token)
  local t = trim(token or "")
  if t == "" then
    return {}
  end
  local sign = ""
  if t:sub(1, 1) == "-" then
    sign = "-"
    t = trim(t:sub(2))
  end
  local a, b = t:match("^(%d+)%.%.(%d+)$")
  if not a or not b then
    return { sign .. t }
  end
  a = tonumber(a)
  b = tonumber(b)
  if not a or not b or b < a or (b - a) > 20000 then
    return { sign .. t }
  end
  local out = {}
  for n = a, b do
    out[#out + 1] = sign .. tostring(n)
  end
  return out
end

local function parse_include_path(lines, start_row, end_row)
  for r = start_row + 1, end_row do
    local raw = trim(lines[r] or "")
    if raw ~= "" and raw:sub(1, 1) ~= "#" and raw:sub(1, 1) ~= "$" then
      local quoted = raw:match('"(.-)"')
      if quoted and quoted ~= "" then
        return trim(quoted)
      end
      local first = trim((raw:match("^([^,%s]+)") or raw))
      if first ~= "" then
        return first
      end
      break
    end
  end
  return nil
end

local function synthetic_id(file_path, row)
  return vim.fn.fnamemodify(file_path, ":t") .. ":" .. tostring(row)
end

local function entype_target_type(entype)
  local e = trim(entype or ""):upper()
  if e == "P" or e == "PS" or e == "ALL" then
    return "part"
  elseif e == "N" or e == "NS" then
    return "node"
  elseif e == "G" or e == "GS" then
    return "geometry"
  elseif e == "E" or e == "ES" then
    return "element"
  end
  return nil
end

local function resolve_include_path(base_file, rel)
  local r = trim(rel or "")
  if r == "" then
    return nil
  end
  r = r:gsub("\\", "/")
  if r:match("^[A-Za-z]:/") or r:match("^/") then
    return vim.fn.fnamemodify(r, ":p")
  end
  local base_dir = vim.fn.fnamemodify(base_file, ":p:h")
  return vim.fn.fnamemodify(base_dir .. "/" .. r, ":p")
end

local function is_model_file(path)
  local p = (path or ""):lower()
  return p:match("%.k$") or p:match("%.key$") or p:match("%.imp$") or p:match("%.inp$")
end

local function split_keyword_blocks(lines)
  local blocks = {}
  local start_row, keyword = nil, nil
  for i, line in ipairs(lines or {}) do
    local kw = parse_keyword(line)
    if kw then
      if start_row then
        blocks[#blocks + 1] = { keyword = keyword, start_row = start_row, end_row = i - 1 }
      end
      start_row = i
      keyword = kw
    elseif is_control_line(line) and start_row then
      blocks[#blocks + 1] = { keyword = keyword, start_row = start_row, end_row = i - 1 }
      start_row = nil
      keyword = nil
    end
  end
  if start_row then
    blocks[#blocks + 1] = { keyword = keyword, start_row = start_row, end_row = #lines }
  end
  return blocks
end

local function collect_data_rows(lines, block)
  local rows = {}
  for r = (block.start_row or 0) + 1, block.end_row or 0 do
    local raw = lines[r] or ""
    if not is_comment_or_blank(raw) and not is_control_line(raw) and not is_title_line(raw) then
      local normalized = trim(strip_number_prefix(raw))
      if not normalized:match("^%-+$")
        and normalized ~= "Variable         Description"
        and normalized:sub(1, 1) ~= "~"
      then
        rows[#rows + 1] = r
      end
    end
  end
  return rows
end

local function new_graph(root)
  return {
    root = root,
    files = {},
    objects = {},
    objects_by_type = {},
    refs_out = {},
    refs_in = {},
    dangling = {},
    stats = {
      files = 0,
      objects = 0,
      refs = 0,
    },
  }
end

local function file_mtime(path)
  local ok, stat = pcall(vim.loop.fs_stat, path)
  if ok and stat and stat.mtime then
    return string.format("%d:%d", stat.mtime.sec or 0, stat.mtime.nsec or 0)
  end
  local t = vim.fn.getftime(path)
  return tostring(t or -1)
end

local function add_object(graph, obj)
  if not obj or not obj.key then
    return
  end
  if graph.objects[obj.key] then
    return
  end
  graph.objects[obj.key] = obj
  graph.objects_by_type[obj.type] = graph.objects_by_type[obj.type] or {}
  graph.objects_by_type[obj.type][obj.id] = obj
  graph.stats.objects = graph.stats.objects + 1
end

local function add_ref(graph, from_key, to_type, to_id, meta)
  local target = tostring(to_type) .. ":" .. tostring(to_id)
  graph.refs_out[from_key] = graph.refs_out[from_key] or {}
  graph.refs_in[target] = graph.refs_in[target] or {}
  local edge = {
    from = from_key,
    to = target,
    to_type = to_type,
    to_id = tostring(to_id),
    meta = meta or {},
  }
  graph.refs_out[from_key][#graph.refs_out[from_key] + 1] = edge
  graph.refs_in[target][#graph.refs_in[target] + 1] = edge
  graph.stats.refs = graph.stats.refs + 1
end

local function merge_graph(dst, src)
  if not src then
    return
  end
  for path, meta in pairs(src.files or {}) do
    if not dst.files[path] then
      dst.files[path] = meta
      dst.stats.files = dst.stats.files + 1
    end
  end
  for _, obj in pairs(src.objects or {}) do
    add_object(dst, obj)
  end
  for _, edges in pairs(src.refs_out or {}) do
    for _, edge in ipairs(edges or {}) do
      add_ref(dst, edge.from, edge.to_type, edge.to_id, edge.meta)
    end
  end
end

local function make_object_key(obj_type, id)
  return tostring(obj_type) .. ":" .. tostring(id)
end

local function parse_part(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then
    return
  end
  for _, row in ipairs(data_rows) do
    local fields = split_csv_outside_quotes(lines[row] or "")
    local pid = trim(fields[1] or "")
    if pid ~= "" and integer_like(pid) then
      local key = make_object_key("part", pid)
      add_object(graph, {
        key = key,
        type = "part",
        id = pid,
        keyword = block.keyword,
        file = file_path,
        row = row,
        fields = fields,
      })
      local mid = trim(fields[2] or "")
      if mid ~= "" and integer_like(mid) then
        add_ref(graph, key, "material", mid, { field = "mid", strength = "semantic" })
      end
    end
  end
end

local function parse_material(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then
    return
  end
  local row = data_rows[1]
  local fields = split_csv_outside_quotes(lines[row] or "")
  local mid = trim(fields[1] or "")
  if block.keyword and block.keyword:upper() == "*MAT_OBJECT" then
    mid = trim(fields[2] or "")
  elseif mid:match('^".*"$') and trim(fields[2] or "") ~= "" then
    mid = trim(fields[2] or "")
  end
  if mid == "" or not integer_like(mid) then
    return
  end
  add_object(graph, {
    key = make_object_key("material", mid),
    type = "material",
    id = mid,
    keyword = block.keyword,
    file = file_path,
    row = row,
    fields = fields,
  })
end

local function infer_material_id_from_fields(block, fields)
  local mid = trim(fields[1] or "")
  local kw = (block.keyword or ""):upper()
  if kw == "*MAT_OBJECT" then
    mid = trim(fields[2] or "")
  elseif mid:match('^".*"$') and trim(fields[2] or "") ~= "" then
    mid = trim(fields[2] or "")
  end
  if mid ~= "" and integer_like(mid) then
    return mid
  end
  return nil
end

local function parse_nodes(graph, file_path, lines, block)
  for _, row in ipairs(collect_data_rows(lines, block)) do
    local fields = split_csv_outside_quotes(lines[row] or "")
    local nid = trim(fields[1] or "")
    if nid ~= "" then
      add_object(graph, {
        key = make_object_key("node", nid),
        type = "node",
        id = nid,
        keyword = block.keyword,
        file = file_path,
        row = row,
        fields = fields,
      })
    end
  end
end

local function parse_elements(graph, file_path, lines, block)
  for _, row in ipairs(collect_data_rows(lines, block)) do
    local fields = split_csv_outside_quotes(lines[row] or "")
    local eid = trim(fields[1] or "")
    if eid ~= "" then
      local key = make_object_key("element", eid)
      add_object(graph, {
        key = key,
        type = "element",
        id = eid,
        keyword = block.keyword,
        file = file_path,
        row = row,
        fields = fields,
      })
      local pid = trim(fields[2] or "")
      if pid ~= "" then
        add_ref(graph, key, "part", pid, { field = "pid", strength = "semantic" })
      end
      for idx = 3, #fields do
        local token = trim(fields[idx] or "")
        if integer_like(token) then
          add_ref(graph, key, "node", token, { field = "n" .. tostring(idx - 2), strength = "structural" })
        end
      end
    end
  end
end

local function parse_set(graph, file_path, lines, block, object_type, member_type)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then
    return
  end
  local set_row = data_rows[1]
  local set_fields = split_csv_outside_quotes(lines[set_row] or "")
  local setid = trim(set_fields[1] or "")
  if setid == "" then
    return
  end
  local key = make_object_key(object_type, setid)
  add_object(graph, {
    key = key,
    type = object_type,
    id = setid,
    keyword = block.keyword,
    file = file_path,
    row = set_row,
    fields = set_fields,
  })
  for i = 2, #data_rows do
    local row = data_rows[i]
    local fields = split_csv_outside_quotes(lines[row] or "")
    for _, token in ipairs(fields) do
      for _, member in ipairs(range_members(token)) do
        local m = trim(member)
        if m ~= "" then
          add_ref(graph, key, member_type, m, { field = "member", row = row, strength = "membership" })
        end
      end
    end
  end
end

local function parse_bc_motion(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then
    return
  end
  local first_fields = split_csv_outside_quotes(lines[data_rows[1]] or "")
  local first = trim(first_fields[1] or "")
  local object_id
  local data_index = 1
  if integer_like(first) then
    object_id = first
    data_index = 2
  else
    object_id = synthetic_id(file_path, block.start_row)
  end
  local key = make_object_key("bc_motion", object_id)
  add_object(graph, {
    key = key,
    type = "bc_motion",
    id = object_id,
    keyword = block.keyword,
    file = file_path,
    row = block.start_row,
    fields = {},
  })
  local target_row = data_rows[data_index]
  if not target_row then
    return
  end
  local fields = split_csv_outside_quotes(lines[target_row] or "")
  local entype = trim(fields[1] or "")
  local typeid = trim(fields[2] or "")
  if entype ~= "" and typeid ~= "" then
    local ref_type = entype_target_type(entype)
    if ref_type then
      add_ref(graph, key, ref_type, typeid, { field = "typeid", entype = entype, strength = "semantic" })
    end
  end
end

local function parse_contact(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then
    return
  end
  local row = data_rows[1]
  local fields = split_csv_outside_quotes(lines[row] or "")
  local cid = trim(fields[1] or "")
  if cid == "" or not integer_like(cid) then
    cid = synthetic_id(file_path, block.start_row)
  end
  local key = make_object_key("contact", cid)
  add_object(graph, {
    key = key,
    type = "contact",
    id = cid,
    keyword = block.keyword,
    file = file_path,
    row = row,
    fields = fields,
  })
  if data_rows[2] then
    local pair = split_csv_outside_quotes(lines[data_rows[2]] or "")
    local entype1, id1 = trim(pair[1] or ""), trim(pair[2] or "")
    local entype2, id2 = trim(pair[3] or ""), trim(pair[4] or "")
    local ref_type1 = entype_target_type(entype1)
    local ref_type2 = entype_target_type(entype2)
    if ref_type1 and id1 ~= "" then
      add_ref(graph, key, ref_type1, id1, { field = "target_1", entype = entype1, strength = "semantic" })
    end
    if ref_type2 and id2 ~= "" then
      add_ref(graph, key, ref_type2, id2, { field = "target_2", entype = entype2, strength = "semantic" })
    end
  end
end

local function parse_component(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then
    return
  end
  local row = data_rows[1]
  local fields = split_csv_outside_quotes(lines[row] or "")
  local coid = trim(fields[1] or "")
  if coid == "" or not integer_like(coid) then
    return
  end
  local key = make_object_key("component", coid)
  add_object(graph, {
    key = key,
    type = "component",
    id = coid,
    keyword = block.keyword,
    file = file_path,
    row = row,
    fields = fields,
  })
  local pid = trim(fields[2] or "")
  if pid ~= "" and integer_like(pid) then
    add_ref(graph, key, "part", pid, { field = "pid", strength = "semantic" })
  end
end

local function parse_output_sensor(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then
    return
  end
  local sid = synthetic_id(file_path, block.start_row)
  local key = make_object_key("output_sensor", sid)
  add_object(graph, {
    key = key,
    type = "output_sensor",
    id = sid,
    keyword = block.keyword,
    file = file_path,
    row = block.start_row,
    fields = split_csv_outside_quotes(lines[data_rows[1]] or ""),
  })
end

local function parse_particle(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then
    return
  end
  local pid = synthetic_id(file_path, block.start_row)
  local key = make_object_key("particle", pid)
  add_object(graph, {
    key = key,
    type = "particle",
    id = pid,
    keyword = block.keyword,
    file = file_path,
    row = block.start_row,
    fields = split_csv_outside_quotes(lines[data_rows[1]] or ""),
  })
end

local function parse_load(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then
    return
  end
  local row = data_rows[1]
  local fields = split_csv_outside_quotes(lines[row] or "")
  local lid = trim(fields[1] or "")
  if lid == "" or not integer_like(lid) then
    lid = synthetic_id(file_path, block.start_row)
  end
  local key = make_object_key("load", lid)
  add_object(graph, {
    key = key,
    type = "load",
    id = lid,
    keyword = block.keyword,
    file = file_path,
    row = row,
    fields = fields,
  })
end

-- INITIAL_VELOCITY, INITIAL_DISPLACEMENT, INITIAL_TEMPERATURE,
-- OUTPUT_ELEMENT, OUTPUT_NODE: entype+enid in first data row, no coid.
local function parse_initial_entype(graph, file_path, lines, block, obj_type)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then return end
  local sid = synthetic_id(file_path, block.start_row)
  local key = make_object_key(obj_type, sid)
  add_object(graph, {
    key = key, type = obj_type, id = sid,
    keyword = block.keyword, file = file_path, row = block.start_row, fields = {},
  })
  local fields = split_csv_outside_quotes(lines[data_rows[1]] or "")
  local entype = trim(fields[1] or "")
  local enid   = trim(fields[2] or "")
  if entype ~= "" and enid ~= "" then
    local ref_type = entype_target_type(entype)
    if ref_type then
      add_ref(graph, key, ref_type, enid, { field = "enid", entype = entype, strength = "semantic" })
    end
  end
end

-- LOAD_FORCE, LOAD_PRESSURE, CONNECTOR_SPOT_WELD*, EROSION_CRITERION:
-- coid in row 1, entype+enid in row 2.
local function parse_coid_entype2(graph, file_path, lines, block, obj_type)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then return end
  local f1 = split_csv_outside_quotes(lines[data_rows[1]] or "")
  local coid = trim(f1[1] or "")
  if coid == "" or not integer_like(coid) then
    coid = synthetic_id(file_path, block.start_row)
  end
  local key = make_object_key(obj_type, coid)
  add_object(graph, {
    key = key, type = obj_type, id = coid,
    keyword = block.keyword, file = file_path, row = data_rows[1], fields = f1,
  })
  if data_rows[2] then
    local f2 = split_csv_outside_quotes(lines[data_rows[2]] or "")
    local entype = trim(f2[1] or "")
    local enid   = trim(f2[2] or "")
    if entype ~= "" and enid ~= "" then
      local ref_type = entype_target_type(entype)
      if ref_type then
        add_ref(graph, key, ref_type, enid, { field = "enid", entype = entype, strength = "semantic" })
      end
    end
  end
end

-- ADD_MASS, INITIAL_PLASTIC_STRAIN_FUNCTION, OUTPUT_SECTION,
-- OUTPUT_CONTACT_FORCE, CONNECTOR_RIGID: coid[1]+entype[2]+enid[3] in row 1.
local function parse_coid_inline_entype(graph, file_path, lines, block, obj_type)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then return end
  local fields = split_csv_outside_quotes(lines[data_rows[1]] or "")
  local coid = trim(fields[1] or "")
  if coid == "" or not integer_like(coid) then
    coid = synthetic_id(file_path, block.start_row)
  end
  local key = make_object_key(obj_type, coid)
  add_object(graph, {
    key = key, type = obj_type, id = coid,
    keyword = block.keyword, file = file_path, row = data_rows[1], fields = fields,
  })
  local entype = trim(fields[2] or "")
  local enid   = trim(fields[3] or "")
  if entype ~= "" and enid ~= "" then
    local ref_type = entype_target_type(entype)
    if ref_type then
      add_ref(graph, key, ref_type, enid, { field = "enid", entype = entype, strength = "semantic" })
    end
  end
end

-- RIGID_BODY_JOINT, CONNECTOR_GLUE_LINE, CONNECTOR_GLUE_SURFACE:
-- coid in row 1, dual (entype_1+enid_1+entype_2+enid_2) in row 2.
local function parse_coid_dual_entype2(graph, file_path, lines, block, obj_type)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then return end
  local f1 = split_csv_outside_quotes(lines[data_rows[1]] or "")
  local coid = trim(f1[1] or "")
  if coid == "" or not integer_like(coid) then
    coid = synthetic_id(file_path, block.start_row)
  end
  local key = make_object_key(obj_type, coid)
  add_object(graph, {
    key = key, type = obj_type, id = coid,
    keyword = block.keyword, file = file_path, row = data_rows[1], fields = f1,
  })
  if data_rows[2] then
    local f2 = split_csv_outside_quotes(lines[data_rows[2]] or "")
    local en1, id1 = trim(f2[1] or ""), trim(f2[2] or "")
    local en2, id2 = trim(f2[3] or ""), trim(f2[4] or "")
    local t1, t2 = entype_target_type(en1), entype_target_type(en2)
    if t1 and id1 ~= "" then
      add_ref(graph, key, t1, id1, { field = "enid_1", entype = en1, strength = "semantic" })
    end
    if t2 and id2 ~= "" then
      add_ref(graph, key, t2, id2, { field = "enid_2", entype = en2, strength = "semantic" })
    end
  end
end

-- FUNCTION, CURVE, COORDINATE_SYSTEM*, GEOMETRY_*, PROP_DAMAGE_*, PROP_SPOT_WELD:
-- pure object definition, id is first integer in first data row.
local function parse_id_object(graph, file_path, lines, block, obj_type)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then return end
  local fields = split_csv_outside_quotes(lines[data_rows[1]] or "")
  local oid = trim(fields[1] or "")
  if oid == "" or not integer_like(oid) then return end
  add_object(graph, {
    key = make_object_key(obj_type, oid),
    type = obj_type,
    id = oid,
    keyword = block.keyword,
    file = file_path,
    row = data_rows[1],
    fields = fields,
  })
end

-- RIGID_BODY_INERTIA: pid[1] in row 1, adds ref to part.
local function parse_rigid_body_inertia(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then return end
  local fields = split_csv_outside_quotes(lines[data_rows[1]] or "")
  local pid = trim(fields[1] or "")
  if pid == "" or not integer_like(pid) then return end
  local key = make_object_key("rigid_body", pid)
  add_object(graph, {
    key = key, type = "rigid_body", id = pid,
    keyword = block.keyword, file = file_path, row = data_rows[1], fields = fields,
  })
  add_ref(graph, key, "part", pid, { field = "pid", strength = "semantic" })
end

-- RIGID_BODY_DAMPING: pid_1[1]+pid_2[2] in row 1, both ref part.
local function parse_rigid_body_damping(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then return end
  local sid = synthetic_id(file_path, block.start_row)
  local key = make_object_key("rigid_body_damping", sid)
  add_object(graph, {
    key = key, type = "rigid_body_damping", id = sid,
    keyword = block.keyword, file = file_path, row = block.start_row, fields = {},
  })
  local fields = split_csv_outside_quotes(lines[data_rows[1]] or "")
  for _, f in ipairs({ fields[1], fields[2] }) do
    local pid = trim(f or "")
    if pid ~= "" and integer_like(pid) then
      add_ref(graph, key, "part", pid, { field = "pid", strength = "semantic" })
    end
  end
end

-- CONNECTOR_SPR: coid[1]+pid_s[2]+pid_m[3] in row 1.
local function parse_connector_spr(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then return end
  local fields = split_csv_outside_quotes(lines[data_rows[1]] or "")
  local coid = trim(fields[1] or "")
  if coid == "" or not integer_like(coid) then
    coid = synthetic_id(file_path, block.start_row)
  end
  local key = make_object_key("connector", coid)
  add_object(graph, {
    key = key, type = "connector", id = coid,
    keyword = block.keyword, file = file_path, row = data_rows[1], fields = fields,
  })
  local pid_s = trim(fields[2] or "")
  local pid_m = trim(fields[3] or "")
  if pid_s ~= "" and integer_like(pid_s) then
    add_ref(graph, key, "part", pid_s, { field = "pid_s", strength = "semantic" })
  end
  if pid_m ~= "" and integer_like(pid_m) then
    add_ref(graph, key, "part", pid_m, { field = "pid_m", strength = "semantic" })
  end
end

-- CONNECTOR_DAMPER: coid in row 1, pid_1[1]+pid_2[2] in row 2.
local function parse_connector_damper(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then return end
  local f1 = split_csv_outside_quotes(lines[data_rows[1]] or "")
  local coid = trim(f1[1] or "")
  if coid == "" or not integer_like(coid) then
    coid = synthetic_id(file_path, block.start_row)
  end
  local key = make_object_key("connector", coid)
  add_object(graph, {
    key = key, type = "connector", id = coid,
    keyword = block.keyword, file = file_path, row = data_rows[1], fields = f1,
  })
  if data_rows[2] then
    local f2 = split_csv_outside_quotes(lines[data_rows[2]] or "")
    for _, f in ipairs({ f2[1], f2[2] }) do
      local pid = trim(f or "")
      if pid ~= "" and integer_like(pid) then
        add_ref(graph, key, "part", pid, { field = "pid", strength = "semantic" })
      end
    end
  end
end

-- SET_GEOMETRY: setid in row 1, geometry members in rows 2+.
local function parse_set_geometry(graph, file_path, lines, block)
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then return end
  local sf = split_csv_outside_quotes(lines[data_rows[1]] or "")
  local setid = trim(sf[1] or "")
  if setid == "" then return end
  local key = make_object_key("set_geometry", setid)
  add_object(graph, {
    key = key, type = "set_geometry", id = setid,
    keyword = block.keyword, file = file_path, row = data_rows[1], fields = sf,
  })
  for i = 2, #data_rows do
    local fields = split_csv_outside_quotes(lines[data_rows[i]] or "")
    for _, token in ipairs(fields) do
      for _, member in ipairs(range_members(token)) do
        local m = trim(member)
        if m ~= "" then
          add_ref(graph, key, "geometry", m, { field = "member", strength = "membership" })
        end
      end
    end
  end
end

local function find_block_at_row(lines, row)
  for _, block in ipairs(split_keyword_blocks(lines)) do
    if row >= (block.start_row or 1) and row <= (block.end_row or 0) then
      return block
    end
  end
  return nil
end

local function pick_relevant_data_row(data_rows, cursor_row)
  if #data_rows == 0 then
    return nil
  end
  for _, row in ipairs(data_rows) do
    if row == cursor_row then
      return row
    end
  end
  local best = nil
  for _, row in ipairs(data_rows) do
    if row <= cursor_row then
      best = row
    end
  end
  return best or data_rows[1]
end

local function infer_object_key_at_cursor(bufnr, row)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if not path or path == "" then
    return nil, "Current buffer has no file path"
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local block = find_block_at_row(lines, row)
  if not block then
    return nil, "Cursor is not inside a keyword block"
  end
  local kw = (block.keyword or ""):upper()
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then
    return nil, "No data rows found in current keyword block"
  end
  local target_row = pick_relevant_data_row(data_rows, row)
  local fields = split_csv_outside_quotes(lines[target_row] or "")

  if kw == "*PART" then
    local pid = trim(fields[1] or "")
    if pid ~= "" and integer_like(pid) then
      return make_object_key("part", pid)
    end
  elseif kw:match("^%*MAT_") then
    local mid = infer_material_id_from_fields(block, fields)
    if mid then
      return make_object_key("material", mid)
    end
  elseif kw == "*NODE" then
    local nid = trim(fields[1] or "")
    if nid ~= "" and integer_like(nid) then
      return make_object_key("node", nid)
    end
  elseif kw:match("^%*ELEMENT_") then
    local eid = trim(fields[1] or "")
    if eid ~= "" and integer_like(eid) then
      return make_object_key("element", eid)
    end
  elseif kw == "*SET_PART" or kw == "*SET_NODE" or kw:match("^%*SET_ELEMENT") then
    local setid = trim(fields[1] or "")
    if setid ~= "" and integer_like(setid) then
      local obj_type = kw == "*SET_PART" and "set_part" or (kw == "*SET_NODE" and "set_node" or "set_element")
      return make_object_key(obj_type, setid)
    end
  elseif kw == "*BC_MOTION" then
    local first = trim(fields[1] or "")
    if first ~= "" and integer_like(first) then
      return make_object_key("bc_motion", first)
    end
    return make_object_key("bc_motion", synthetic_id(path, block.start_row))
  elseif kw == "*CONTACT" then
    local cid = trim(fields[1] or "")
    if cid == "" or not integer_like(cid) then
      cid = synthetic_id(path, block.start_row)
    end
    return make_object_key("contact", cid)
  elseif kw:match("^%*COMPONENT_") then
    local coid = trim(fields[1] or "")
    if coid ~= "" and integer_like(coid) then
      return make_object_key("component", coid)
    end
  elseif kw == "*OUTPUT_SENSOR" or kw == "*OUTPUT_SENSOR_EXTENDED" or kw == "*OUTPUT_SENSOR_PATH" or kw == "*OUTPUT_SENSOR_THICKNESS" then
    return make_object_key("output_sensor", synthetic_id(path, block.start_row))
  elseif kw:match("^%*PARTICLE_") then
    return make_object_key("particle", synthetic_id(path, block.start_row))
  elseif kw == "*LOAD_FORCE" or kw == "*LOAD_PRESSURE" then
    local coid = trim(fields[1] or "")
    if coid == "" or not integer_like(coid) then coid = synthetic_id(path, block.start_row) end
    return make_object_key("load", coid)
  elseif kw:match("^%*LOAD_") then
    local lid = trim(fields[1] or "")
    if lid == "" or not integer_like(lid) then
      lid = synthetic_id(path, block.start_row)
    end
    return make_object_key("load", lid)
  elseif kw == "*INITIAL_VELOCITY" or kw == "*INITIAL_DISPLACEMENT" or kw == "*INITIAL_TEMPERATURE"
    or kw == "*INITIAL_PLASTIC_STRAIN_FUNCTION" then
    return make_object_key("initial_condition", synthetic_id(path, block.start_row))
  elseif kw == "*OUTPUT_ELEMENT" or kw == "*OUTPUT_NODE"
    or kw == "*OUTPUT_SECTION" or kw == "*OUTPUT_CONTACT_FORCE" then
    return make_object_key("output", synthetic_id(path, block.start_row))
  elseif kw == "*RIGID_BODY_INERTIA" then
    local pid = trim(fields[1] or "")
    if pid ~= "" and integer_like(pid) then
      return make_object_key("rigid_body", pid)
    end
  elseif kw == "*RIGID_BODY_DAMPING" then
    return make_object_key("rigid_body_damping", synthetic_id(path, block.start_row))
  elseif kw == "*RIGID_BODY_JOINT" then
    local coid = trim(fields[1] or "")
    if coid == "" or not integer_like(coid) then coid = synthetic_id(path, block.start_row) end
    return make_object_key("rigid_body_joint", coid)
  elseif kw == "*RIGID_BODY_ADD_NODES" then
    local coid = trim(fields[1] or "")
    if coid == "" or not integer_like(coid) then coid = synthetic_id(path, block.start_row) end
    return make_object_key("rigid_body_add_nodes", coid)
  elseif kw == "*CONNECTOR_RIGID" or kw == "*CONNECTOR_SPOT_WELD" or kw == "*CONNECTOR_SPOT_WELD_NODE"
    or kw == "*CONNECTOR_GLUE_LINE" or kw == "*CONNECTOR_GLUE_SURFACE"
    or kw == "*CONNECTOR_SPR" or kw == "*CONNECTOR_DAMPER" then
    local coid = trim(fields[1] or "")
    if coid == "" or not integer_like(coid) then coid = synthetic_id(path, block.start_row) end
    return make_object_key("connector", coid)
  elseif kw == "*ADD_MASS" or kw == "*EROSION_CRITERION" then
    local coid = trim(fields[1] or "")
    if coid == "" or not integer_like(coid) then coid = synthetic_id(path, block.start_row) end
    return make_object_key(kw == "*EROSION_CRITERION" and "erosion_criterion" or "load", coid)
  elseif kw == "*FUNCTION" then
    local fid = trim(fields[1] or "")
    if fid ~= "" and integer_like(fid) then return make_object_key("function", fid) end
  elseif kw == "*CURVE" then
    local cid = trim(fields[1] or "")
    if cid ~= "" and integer_like(cid) then return make_object_key("curve", cid) end
  elseif kw:match("^%*COORDINATE_SYSTEM") then
    local csid = trim(fields[1] or "")
    if csid ~= "" and integer_like(csid) then return make_object_key("coordinate_system", csid) end
  elseif kw:match("^%*GEOMETRY_") then
    local gid = trim(fields[1] or "")
    if gid ~= "" and integer_like(gid) then return make_object_key("geometry", gid) end
  elseif kw:match("^%*PROP_DAMAGE_") or kw == "*PROP_SPOT_WELD" or kw == "*PROP_THERMAL" then
    local did = trim(fields[1] or "")
    if did ~= "" and integer_like(did) then return make_object_key("property", did) end
  elseif kw == "*SET_GEOMETRY" then
    local setid = trim(fields[1] or "")
    if setid ~= "" and integer_like(setid) then return make_object_key("set_geometry", setid) end
  end

  return nil, "Current row does not map to a supported object yet"
end

local function build_subtree_from_lines(path, lines, stack, seen)
  local subtree = new_graph(path)
  subtree.files[path] = { line_count = #lines }
  subtree.stats.files = 1
  seen[path] = true

  local blocks = split_keyword_blocks(lines)
  for _, block in ipairs(blocks) do
    local kw = (block.keyword or ""):upper()
    if kw == "*INCLUDE" then
      local rel = parse_include_path(lines, block.start_row, block.end_row)
      local child = resolve_include_path(path, rel)
      if child and is_model_file(child) and not stack[child] and not seen[child] then
        local child_subtree = nil
        local mtime = file_mtime(child)
        local cached = subtree_cache[child]
        if cached and cached.mtime == mtime then
          child_subtree = cached.graph
        elseif vim.fn.filereadable(child) == 1 then
          stack[child] = true
          child_subtree = build_subtree_from_lines(child, vim.fn.readfile(child), stack, seen)
          stack[child] = nil
          subtree_cache[child] = {
            mtime = mtime,
            graph = child_subtree,
          }
        end
        merge_graph(subtree, child_subtree)
      end
    elseif kw == "*NODE" then
      parse_nodes(subtree, path, lines, block)
    elseif kw:match("^%*ELEMENT_") then
      parse_elements(subtree, path, lines, block)
    elseif kw == "*PART" then
      parse_part(subtree, path, lines, block)
    elseif kw:match("^%*MAT_") then
      parse_material(subtree, path, lines, block)
    elseif kw == "*SET_PART" then
      parse_set(subtree, path, lines, block, "set_part", "part")
    elseif kw == "*SET_NODE" then
      parse_set(subtree, path, lines, block, "set_node", "node")
    elseif kw:match("^%*SET_ELEMENT") then
      parse_set(subtree, path, lines, block, "set_element", "element")
    elseif kw == "*BC_MOTION" then
      parse_bc_motion(subtree, path, lines, block)
    elseif kw == "*CONTACT" then
      parse_contact(subtree, path, lines, block)
    elseif kw:match("^%*COMPONENT_") then
      parse_component(subtree, path, lines, block)
    elseif kw == "*OUTPUT_SENSOR" or kw == "*OUTPUT_SENSOR_EXTENDED" or kw == "*OUTPUT_SENSOR_PATH" or kw == "*OUTPUT_SENSOR_THICKNESS" then
      parse_output_sensor(subtree, path, lines, block)
    elseif kw:match("^%*PARTICLE_") then
      parse_particle(subtree, path, lines, block)
    -- Specific LOAD_ variants with entype refs before the generic catch-all
    elseif kw == "*LOAD_FORCE" or kw == "*LOAD_PRESSURE" then
      parse_coid_entype2(subtree, path, lines, block, "load")
    elseif kw:match("^%*LOAD_") then
      parse_load(subtree, path, lines, block)
    -- INITIAL conditions
    elseif kw == "*INITIAL_VELOCITY" or kw == "*INITIAL_DISPLACEMENT" or kw == "*INITIAL_TEMPERATURE" then
      parse_initial_entype(subtree, path, lines, block, "initial_condition")
    elseif kw == "*INITIAL_PLASTIC_STRAIN_FUNCTION" then
      parse_coid_inline_entype(subtree, path, lines, block, "initial_condition")
    -- OUTPUT
    elseif kw == "*OUTPUT_ELEMENT" or kw == "*OUTPUT_NODE" then
      parse_initial_entype(subtree, path, lines, block, "output")
    elseif kw == "*OUTPUT_SECTION" or kw == "*OUTPUT_CONTACT_FORCE" then
      parse_coid_inline_entype(subtree, path, lines, block, "output")
    -- RIGID_BODY
    elseif kw == "*RIGID_BODY_INERTIA" then
      parse_rigid_body_inertia(subtree, path, lines, block)
    elseif kw == "*RIGID_BODY_DAMPING" then
      parse_rigid_body_damping(subtree, path, lines, block)
    elseif kw == "*RIGID_BODY_JOINT" then
      parse_coid_dual_entype2(subtree, path, lines, block, "rigid_body_joint")
    elseif kw == "*RIGID_BODY_ADD_NODES" then
      parse_coid_entype2(subtree, path, lines, block, "rigid_body_add_nodes")
    -- CONNECTOR
    elseif kw == "*CONNECTOR_RIGID" then
      parse_coid_inline_entype(subtree, path, lines, block, "connector")
    elseif kw == "*CONNECTOR_SPOT_WELD" or kw == "*CONNECTOR_SPOT_WELD_NODE" then
      parse_coid_entype2(subtree, path, lines, block, "connector")
    elseif kw == "*CONNECTOR_GLUE_LINE" or kw == "*CONNECTOR_GLUE_SURFACE" then
      parse_coid_dual_entype2(subtree, path, lines, block, "connector")
    elseif kw == "*CONNECTOR_SPR" then
      parse_connector_spr(subtree, path, lines, block)
    elseif kw == "*CONNECTOR_DAMPER" then
      parse_connector_damper(subtree, path, lines, block)
    -- ADD_MASS / EROSION
    elseif kw == "*ADD_MASS" then
      parse_coid_inline_entype(subtree, path, lines, block, "load")
    elseif kw == "*EROSION_CRITERION" then
      parse_coid_entype2(subtree, path, lines, block, "erosion_criterion")
    -- Object definitions
    elseif kw == "*FUNCTION" then
      parse_id_object(subtree, path, lines, block, "function")
    elseif kw == "*CURVE" then
      parse_id_object(subtree, path, lines, block, "curve")
    elseif kw:match("^%*COORDINATE_SYSTEM") then
      parse_id_object(subtree, path, lines, block, "coordinate_system")
    elseif kw:match("^%*GEOMETRY_") then
      parse_id_object(subtree, path, lines, block, "geometry")
    elseif kw:match("^%*PROP_DAMAGE_") or kw == "*PROP_SPOT_WELD" or kw == "*PROP_THERMAL" then
      parse_id_object(subtree, path, lines, block, "property")
    elseif kw == "*SET_GEOMETRY" then
      parse_set_geometry(subtree, path, lines, block)
    end
  end
  return subtree
end

local function build_subtree_for_file(file_path)
  local path = vim.fn.fnamemodify(file_path, ":p")
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local mtime = file_mtime(path)
  local cached = subtree_cache[path]
  if cached and cached.mtime == mtime then
    return cached.graph
  end
  local stack = { [path] = true }
  local subtree = build_subtree_from_lines(path, vim.fn.readfile(path), stack, {})
  subtree_cache[path] = {
    mtime = mtime,
    graph = subtree,
  }
  return subtree
end

local function finalize_dangling(graph)
  for from_key, edges in pairs(graph.refs_out) do
    for _, edge in ipairs(edges or {}) do
      if not graph.objects[edge.to] then
        graph.dangling[#graph.dangling + 1] = {
          from = from_key,
          to = edge.to,
          meta = edge.meta or {},
        }
      end
    end
  end
  table.sort(graph.dangling, function(a, b)
    if a.from ~= b.from then
      return a.from < b.from
    end
    return a.to < b.to
  end)
end

function M.build_for_file(path)
  local root = vim.fn.fnamemodify(path, ":p")
  local mtime = file_mtime(root)
  local cached = file_graph_cache[root]
  if cached and cached.mtime == mtime then
    return cached.graph
  end
  local graph = new_graph(root)
  merge_graph(graph, build_subtree_for_file(root))
  finalize_dangling(graph)
  file_graph_cache[root] = {
    mtime = mtime,
    graph = graph,
  }
  return graph
end

function M.invalidate_current_buffer_cache(bufnr)
  if bufnr then
    current_buffer_graph_cache[bufnr] = nil
  else
    current_buffer_graph_cache = {}
  end
end

function M.invalidate_file_cache(path)
  if path then
    local root = vim.fn.fnamemodify(path, ":p")
    file_graph_cache[root] = nil
    subtree_cache[root] = nil
  else
    file_graph_cache = {}
    subtree_cache = {}
  end
end

function M.build_for_current_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if not path or path == "" then
    return nil, "Current buffer has no file path"
  end
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = current_buffer_graph_cache[bufnr]
  if cached
    and cached.path == path
    and cached.changedtick == changedtick
  then
    return cached.graph
  end
  local root = vim.fn.fnamemodify(path, ":p")
  local graph = new_graph(root)
  local stack = { [root] = true }
  merge_graph(graph, build_subtree_from_lines(root, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), stack, {}))
  finalize_dangling(graph)
  current_buffer_graph_cache[bufnr] = {
    path = path,
    changedtick = changedtick,
    graph = graph,
  }
  return graph
end

local function count_by_type(graph)
  if graph._object_counts then
    return graph._object_counts
  end
  local out = {}
  for obj_type, items in pairs(graph.objects_by_type or {}) do
    local n = 0
    for _, _ in pairs(items or {}) do
      n = n + 1
    end
    out[#out + 1] = { type = obj_type, count = n }
  end
  table.sort(out, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.type < b.type
  end)
  graph._object_counts = out
  return out
end

local function count_refs_by_target_type(graph)
  if graph._ref_counts_by_target_type then
    return graph._ref_counts_by_target_type
  end
  local counts = {}
  for _, edges in pairs(graph.refs_out or {}) do
    for _, edge in ipairs(edges or {}) do
      counts[edge.to_type] = (counts[edge.to_type] or 0) + 1
    end
  end
  local out = {}
  for obj_type, count in pairs(counts) do
    out[#out + 1] = { type = obj_type, count = count }
  end
  table.sort(out, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.type < b.type
  end)
  graph._ref_counts_by_target_type = out
  return out
end

local function top_inbound_objects(graph, limit)
  graph._top_inbound_objects = graph._top_inbound_objects or {}
  if graph._top_inbound_objects[limit or 20] then
    return graph._top_inbound_objects[limit or 20]
  end
  local out = {}
  for target, edges in pairs(graph.refs_in or {}) do
    out[#out + 1] = {
      target = target,
      count = #(edges or {}),
    }
  end
  table.sort(out, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.target < b.target
  end)
  if #out > (limit or 20) then
    local trimmed = {}
    for i = 1, (limit or 20) do
      trimmed[#trimmed + 1] = out[i]
    end
    graph._top_inbound_objects[limit or 20] = trimmed
    return trimmed
  end
  graph._top_inbound_objects[limit or 20] = out
  return out
end

function M.render_summary_lines(graph)
  local lines = {
    "IMPETUS OBJECT GRAPH",
    string.rep("=", 72),
    "Root file: " .. tostring(graph.root or ""),
    "",
    string.format("Files: %d", graph.stats.files or 0),
    string.format("Objects: %d", graph.stats.objects or 0),
    string.format("References: %d", graph.stats.refs or 0),
    string.format("Dangling refs: %d", #(graph.dangling or {})),
    "",
    "[Object Counts]",
  }

  for _, item in ipairs(count_by_type(graph)) do
    lines[#lines + 1] = string.format("%-16s %6d", item.type, item.count)
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "[Reference Counts By Target Type]"
  local ref_counts = count_refs_by_target_type(graph)
  if #ref_counts == 0 then
    lines[#lines + 1] = "(none)"
  else
    for _, item in ipairs(ref_counts) do
      lines[#lines + 1] = string.format("%-16s %6d", item.type, item.count)
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "[Most Referenced Objects]"
  local inbound = top_inbound_objects(graph, 20)
  if #inbound == 0 then
    lines[#lines + 1] = "(none)"
  else
    for _, item in ipairs(inbound) do
      lines[#lines + 1] = string.format("%-24s %6d", item.target, item.count)
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "[Dangling References]"
  if #(graph.dangling or {}) == 0 then
    lines[#lines + 1] = "(none)"
  else
    local shown = math.min(#graph.dangling, 120)
    lines[#lines + 1] = string.format("Showing %d of %d", shown, #graph.dangling)
    for i = 1, shown do
      local d = graph.dangling[i]
      lines[#lines + 1] = string.format("%s -> %s", d.from, d.to)
    end
    if #graph.dangling > shown then
      lines[#lines + 1] = string.format("... %d more", #graph.dangling - shown)
    end
  end
  return lines
end

function M.render_object_refs_lines(graph, object_key)
  local obj = graph.objects[object_key]
  if not obj then
    return {
      "IMPETUS OBJECT REFS",
      string.rep("=", 72),
      "Object not found: " .. tostring(object_key),
    }
  end

  local lines = {
    "IMPETUS OBJECT REFS",
    string.rep("=", 72),
    "Object: " .. object_key,
    "Keyword: " .. tostring(obj.keyword or ""),
    "File: " .. tostring(obj.file or ""),
    "Row: " .. tostring(obj.row or 0),
    "",
    "[Outbound References]",
  }

  local out_edges = graph.refs_out[object_key] or {}
  if #out_edges == 0 then
    lines[#lines + 1] = "(none)"
  else
    for _, edge in ipairs(out_edges) do
      lines[#lines + 1] = string.format("%s -> %s (%s)", object_key, edge.to, tostring((edge.meta or {}).field or "?"))
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "[Inbound References]"
  local in_edges = graph.refs_in[object_key] or {}
  if #in_edges == 0 then
    lines[#lines + 1] = "(none)"
  else
    for _, edge in ipairs(in_edges) do
      local from_obj = graph.objects[edge.from]
      if from_obj then
        lines[#lines + 1] = string.format(
          "%s (%s @ %s:%s) -> %s",
          edge.from,
          tostring(from_obj.keyword or ""),
          vim.fn.fnamemodify(from_obj.file or "", ":t"),
          tostring(from_obj.row or 0),
          object_key
        )
      else
        lines[#lines + 1] = string.format("%s -> %s", edge.from, object_key)
      end
    end
  end

  return lines
end

function M.render_delete_check_lines(graph, object_key)
  local obj = graph.objects[object_key]
  if not obj then
    return {
      "IMPETUS DELETE CHECK",
      string.rep("=", 72),
      "Object not found: " .. tostring(object_key),
    }
  end

  local inbound = graph.refs_in[object_key] or {}
  local structural = {}
  local semantic = {}
  local membership = {}
  for _, edge in ipairs(inbound) do
    local strength = ((edge.meta or {}).strength or "semantic")
    if strength == "structural" then
      structural[#structural + 1] = edge
    elseif strength == "membership" then
      membership[#membership + 1] = edge
    else
      semantic[#semantic + 1] = edge
    end
  end
  local lines = {
    "IMPETUS DELETE CHECK",
    string.rep("=", 72),
    "Object: " .. object_key,
    "Keyword: " .. tostring(obj.keyword or ""),
    "File: " .. tostring(obj.file or ""),
    "Row: " .. tostring(obj.row or 0),
    "",
  }

  if #inbound == 0 then
    lines[#lines + 1] = "Status: SAFE TO DELETE (no inbound references found)"
    return lines
  end

  if #structural > 0 then
    lines[#lines + 1] = string.format(
      "Status: BLOCKED (structural dependency, %d inbound references found)",
      #inbound
    )
  else
    lines[#lines + 1] = string.format(
      "Status: ALLOWED WITH IMPACT (%d inbound references found)",
      #inbound
    )
  end
  lines[#lines + 1] = string.format(
    "Summary: structural=%d  semantic=%d  membership=%d",
    #structural,
    #semantic,
    #membership
  )
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[Inbound References]"

  local function append_edges(title, edges)
    if #edges == 0 then
      return
    end
    lines[#lines + 1] = title
    for _, edge in ipairs(edges) do
      local from_obj = graph.objects[edge.from]
      if from_obj then
        lines[#lines + 1] = string.format(
          "  %s (%s @ %s:%s) -> %s",
          edge.from,
          tostring(from_obj.keyword or ""),
          vim.fn.fnamemodify(from_obj.file or "", ":t"),
          tostring(from_obj.row or 0),
          object_key
        )
      else
        lines[#lines + 1] = string.format("  %s -> %s", edge.from, object_key)
      end
    end
  end

  append_edges("[Structural]", structural)
  append_edges("[Semantic]", semantic)
  append_edges("[Membership]", membership)

  if #structural == 0 and (#semantic > 0 or #membership > 0) then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Note: deletion is logically allowed, but the referencing objects will need follow-up updates."
  end

  return lines
end

function M.open_summary_for_current_buffer()
  local graph, err = M.build_for_current_buffer()
  if not graph then
    vim.notify(err or "Failed to build object graph", vim.log.levels.ERROR)
    return
  end

  local lines = M.render_summary_lines(graph)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = "markdown"

  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
end

function M.open_refs_for_current_buffer(object_key)
  local graph, err = M.build_for_current_buffer()
  if not graph then
    vim.notify(err or "Failed to build object graph", vim.log.levels.ERROR)
    return
  end

  local key = trim(object_key or "")
  if key == "" then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    key, err = infer_object_key_at_cursor(0, row)
    if not key then
      vim.notify(err or "No supported object found under cursor", vim.log.levels.WARN)
      return
    end
  end

  local lines = M.render_object_refs_lines(graph, key)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = "markdown"

  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
end

function M.open_delete_check_for_current_buffer(object_key)
  local graph, err = M.build_for_current_buffer()
  if not graph then
    vim.notify(err or "Failed to build object graph", vim.log.levels.ERROR)
    return
  end

  local key = trim(object_key or "")
  if key == "" then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    key, err = infer_object_key_at_cursor(0, row)
    if not key then
      vim.notify(err or "No supported object found under cursor", vim.log.levels.WARN)
      return
    end
  end

  local lines = M.render_delete_check_lines(graph, key)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = "markdown"

  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
end

return M
