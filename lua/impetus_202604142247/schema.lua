local M = {}

local function normalize_keyword(keyword)
  return (keyword or ""):upper()
end

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_csv_keep_empty(line)
  local out = {}
  local s = (line or "") .. ","
  for part in s:gmatch("(.-),") do
    out[#out + 1] = trim(part)
  end
  return out
end

local function is_int_token(v)
  local t = trim(v)
  if t == "" then
    return false
  end
  if t:match("^[+-]?%d+$") then
    return true
  end
  if t:match("^[+-]?%d+%.0+$") then
    return true
  end
  if t:match("^[+-]?%d+[eE][+%-]?0+$") then
    return true
  end
  if t:match("^[+-]?%d+%.0+[eE][+%-]?%d+$") then
    return true
  end
  return false
end

local function is_real_token(v)
  local t = trim(v)
  if t == "" then
    return false
  end
  if t:match("^[+-]?%d+%.?%d*[eE][+-]?%d+$") then
    return true
  end
  if t:match("^[+-]?%d+%.%d*$") then
    return true
  end
  if t:match("^[+-]?%d*%.%d+$") then
    return true
  end
  if t:match("^[+-]?%d+$") then
    return true
  end
  return false
end

local function is_quoted_string(v)
  local t = trim(v)
  return t:match('^".*"$') ~= nil
end

local function is_param_ref(v)
  local t = trim(v)
  return t:match("^%%[%w_]+$") ~= nil or t:match("^%[%%[%w_]+%]$") ~= nil
end

local function is_simple_expr(v)
  local t = trim(v)
  if t == "" then
    return false
  end
  if is_real_token(t) or is_int_token(t) or is_param_ref(t) then
    return true
  end
  if is_quoted_string(t) then
    return true
  end
  if t:match("^fcn%([^%)]+%)$") then
    return true
  end
  if t:find("[%+%-%*/%(%)]") and not t:match("[A-DF-Za-df-z]") then
    return true
  end
  if t:match("^[%[%]%%%w_%+%-%*/%(%).eE]+$") then
    return true
  end
  return false
end

local function is_identifier_name(v)
  local t = trim(v)
  return t:match("^%%?[%a_][%w_]*$") ~= nil
end

local function in_set(v, allowed)
  local t = trim(v):upper()
  for _, a in ipairs(allowed or {}) do
    if t == a then
      return true
    end
  end
  return false
end

local function is_blank_or_expr(v)
  local t = trim(v)
  return t == "" or t == "-" or is_simple_expr(t)
end

local function is_numericish_expr(v)
  local t = trim(v)
  if t == "" or t == "-" then
    return true
  end
  if is_int_token(t) or is_real_token(t) or is_param_ref(t) then
    return true
  end
  if t:match("^fcn%([^%)]+%)$") then
    return true
  end
  if not (t:find("%%", 1, true) or t:find("%[", 1, true) or t:find("%d")) then
    return false
  end
  if t:match("^[%[%]%%%w_%+%-%*/%(%).eE]+$") then
    return true
  end
  return false
end

local function is_set_range_token(v)
  local t = trim(v)
  if t == "" then
    return false
  end
  if is_int_token(t) then
    return true
  end
  if t:match("^[+-]?%d+%.0+$") then
    return true
  end
  if t:match("^[+-]?%d+%.?0*%.?%.?[+-]?%d+%.?0*$") then
    return false
  end
  if t:match("^%-?%d+%.?0*%.?%.%-?%d+%.?0*$") then
    return true
  end
  if t:match("^%-?%%[%a_][%w_]*%.%.%-?%%[%a_][%w_]*$") then
    return true
  end
  if t:match("^%-?%%[%a_][%w_]*$") then
    return true
  end
  if t:match("^%-?%[%s*%%[%a_][%w_]*%s*%]$") then
    return true
  end
  if t:match("^%-?%[%s*%%[%a_][%w_]*%s*%]%.%.%-?%[%s*%%[%a_][%w_]*%s*%]$") then
    return true
  end
  return false
end

local function all_fields_match(fields, validator)
  for _, f in ipairs(fields or {}) do
    if not validator(f) then
      return false
    end
  end
  return true
end

local function is_path_like(v)
  local t = trim(v)
  if t == "" then
    return false
  end
  if is_quoted_string(t) then
    return true
  end
  if t:match("^[A-Za-z]:[\\/].+") then
    return true
  end
  if t:match("^[%w%._%-%/\\]+%.[A-Za-z0-9_]+$") then
    return true
  end
  return false
end

local function normalize_param_name(name)
  local t = trim(name or ""):lower()
  t = t:gsub('^"+', ""):gsub('"+$', "")
  return t
end

local function generic_enum_for_name(name)
  local n = normalize_param_name(name)
  if n == "entype" or n:match("^entype_") then
    return { "N", "NS", "E", "ES", "P", "PS", "ALL", "G", "GS", "DP", "SPH", "FS", "PATH", "M", "RB", "CFD" }
  end
  if n == "etype" or n:match("^etype_") then
    return { "N", "NS", "E", "ES", "P", "PS", "ALL", "G", "GS", "DP", "SPH", "FS", "PATH", "M", "RB", "CFD" }
  end
  if n == "type_x" or n == "type_y" then
    return { "TIME", "LENGTH", "DISP", "VELO", "ACC", "FORCE", "STRESS", "STRAIN", "PRESSURE", "TEMP", "ENERGY", "NONE" }
  end
  if n == "bc_tr" or n == "bc_rot" then
    return { "0", "X", "Y", "Z", "XY", "YZ", "ZX", "XYZ" }
  end
  if n == "direc" or n:match("^direc_") then
    return { "X", "Y", "Z", "RX", "RY", "RZ" }
  end
  if n:match("^pmeth") then
    return { "A", "V", "D" }
  end
  if n == "plane" then
    return { "0", "X", "Y", "Z", "XY", "YZ", "ZX", "XYZ" }
  end
  if n == "order" then
    return { "1", "2", "3" }
  end
  if n == "itype" then
    return { "1", "2" }
  end
  if n == "path" then
    return { "0", "1" }
  end
  if n == "ground" then
    return { "X", "Y", "Z" }
  end
  if n == "ref" or n == "fixed" or n == "lagrange" or n == "velocity" or n == "multiple" or n == "follow" or n == "air" or n == "output" or n == "pambient" then
    return { "0", "1" }
  end
  if n == "dptype" then
    return { "N", "E" }
  end
  if n == "scheme" then
    return { "1", "2" }
  end
  if n == "stype" then
    return { "0", "1", "2" }
  end
  if n == "merge" or n == "one_way" or n == "no_internal" or n == "fric_heat" or n == "multi" or n == "form" then
    return { "0", "1" }
  end
  return nil
end

local function validate_field_by_name(param_name, value)
  local n = normalize_param_name(param_name)
  local v = trim(value or "")

  if n == "..." then
    return true
  end

  if n == "" or n == "." or n == "-" then
    return v == "" or v == "-"
  end

  if n:match("^range_") then
    return is_set_range_token(v)
  end

  local enum = generic_enum_for_name(n)
  if enum then
    return in_set(v, enum)
  end

  if n == "filename" then
    return is_path_like(v)
  end
  if n == "python_file_name" then
    return is_path_like(v)
  end

  if n:match("^[nempgcfdtrsxbuyz]*id$") or n:find("id_") or n:match("^id%d*$") or n == "coid" or n == "ctid" or n == "setid" or n == "pathid" then
    return is_numericish_expr(v)
  end

  if n:match("^[xyzuvw]_[0-9a-z]+$") or n:match("^[xyzuvw]$") or n:match("^[xyz]_[xyz0-9]+$") then
    return is_blank_or_expr(v)
  end

  if n:match("^fcn_") or n:match("^fid_") or n:match("^cid_") then
    return is_blank_or_expr(v)
  end

  if n:match("^r[_0-9a-z]*$") or n == "e" or n == "rho" or n == "h" or n == "m" or n == "c" or n == "b" or n == "d" or n == "l" or n:match("^sf_") or n:match("^fval_") then
    return is_blank_or_expr(v)
  end

  if n:match("^n_[xyz12345678]$") or n == "n" or n == "nx" or n == "ny" or n == "nz" or n:match("^n[_0-9a-z]+$") then
    return is_blank_or_expr(v) and (v == "" or v == "-" or is_int_token(v) or is_param_ref(v) or is_simple_expr(v))
  end

  if n:match("^t_") or n == "time" then
    return is_blank_or_expr(v)
  end

  if n:match("^name_") then
    return is_quoted_string(v) or v ~= ""
  end

  if n == "message" or n == "error" then
    return v ~= ""
  end

  return is_blank_or_expr(v)
end

local function validate_by_signature_row(fields, row_spec)
  if not row_spec or #row_spec == 0 then
    return nil
  end

  local last_used = 0
  for i, value in ipairs(fields or {}) do
    if trim(value or "") ~= "" then
      last_used = i
    end
  end

  if last_used == 0 then
    return false
  end

  if last_used > #row_spec then
    return false
  end

  for i = 1, last_used do
    local spec = row_spec[i]
    if not validate_field_by_name(spec, fields[i]) then
      return false
    end
  end

  return true
end

local function description_marks_optional(desc)
  local d = trim(desc or ""):lower()
  if d == "" then
    return false
  end
  if d:find("optional", 1, true) then
    return true
  end
  if d:find("only used if", 1, true) then
    return true
  end
  if d:find("default: not used", 1, true) then
    return true
  end
  if d:find("default: no ", 1, true) then
    return true
  end
  return false
end

local function infer_optional_rows(entry)
  local out = {}
  if not entry or not entry.signature_rows or not entry.descriptions then
    return out
  end
  for i, row in ipairs(entry.signature_rows) do
    if type(row) == "table" and #row > 0 then
      local all_optional = true
      for _, name in ipairs(row) do
        local desc = entry.descriptions[name]
        if not description_marks_optional(desc) then
          all_optional = false
          break
        end
      end
      if all_optional then
        out[i] = true
      end
    end
  end
  return out
end

local full_repeat_exact = {
  ["*NODE"] = true,
  ["*PARAMETER"] = true,
  ["*PARAMETER_DEFAULT"] = true,
  ["*CHANGE_P-ORDER"] = true,
  ["*TRIM_HOLE"] = true,
  ["*TABLE"] = true,
  ["*TRANSFORM_MESH_CARTESIAN"] = true,
}

local function infer_repeat_mode(keyword)
  local kw = normalize_keyword(keyword)
  if kw == "" then
    return "schema"
  end
  if kw == "*SCRIPT_PYTHON" then
    return "full_repeat_all"
  end
  if full_repeat_exact[kw] then
    return "full_repeat"
  end
  if kw:match("^%*SET_") then
    return "tail_repeat"
  end
  if kw:match("^%*ELEMENT_") then
    return "full_repeat"
  end
  if kw:match("^%*PART_REFINE") then
    return "full_repeat"
  end
  if kw == "*BC_MOTION" then
    return "tail_repeat"
  end
  if kw == "*PART" then
    return "paired_repeat"
  end
  if kw == "*MERGE" then
    return "group_repeat"
  end
  if kw == "*MAT_OBJECT" then
    return "full_repeat"
  end
  if kw == "*CURVE" then
    return "tail_repeat"
  end
  if kw == "*OUTPUT_SENSOR_EXTENDED" or kw == "*OUTPUT_USER" then
    return "tail_repeat"
  end
  if kw == "*OBJECT" then
    return "tail_repeat"
  end
  if kw == "*INCLUDE" then
    return "schema"
  end
  if kw == "*GENERATE_PARTICLE_DISTRIBUTION" then
    return "schema"
  end
  return "schema"
end

function M.keyword_meta(keyword, entry)
  local kw = normalize_keyword(keyword)
  local repeat_mode = infer_repeat_mode(keyword)
  local tail_repeat_from_row = nil
  local tail_repeat_fields = nil
  local optional_rows = infer_optional_rows(entry)

  if kw == "*OBJECT" then
    return {
      repeat_mode = "tail_repeat",
      tail_repeat_from_row = 4,
      tail_repeat_fields = 2,
      optional_rows = optional_rows,
    }
  end

  if kw:match("^%*SET_") then
    return {
      repeat_mode = "tail_repeat",
      tail_repeat_from_row = 2,
      tail_repeat_fields = nil,
      optional_rows = optional_rows,
    }
  end

  if kw == "*INCLUDE" then
    optional_rows[2] = true
    optional_rows[3] = true
    optional_rows[4] = true
  end

  if kw == "*BC_MOTION" then
    optional_rows[1] = true
    optional_rows[3] = true
    return {
      repeat_mode = "tail_repeat",
      tail_repeat_from_row = 2,
      tail_repeat_fields = nil,
      optional_rows = optional_rows,
    }
  end

  if kw == "*GENERATE_PARTICLE_DISTRIBUTION" then
    optional_rows[3] = true
  end

  if entry and entry.signature_rows and #entry.signature_rows > 0 then
    if repeat_mode == "schema" then
      for i, row in ipairs(entry.signature_rows) do
        if #row == 1 and trim(row[1] or "") == "." then
          repeat_mode = "tail_repeat"
          tail_repeat_from_row = math.max(1, i - 1)
          break
        end
      end
    end
    if repeat_mode == "tail_repeat" then
      tail_repeat_from_row = tail_repeat_from_row or #entry.signature_rows
      local last = entry.signature_rows[#entry.signature_rows] or {}
      if #last == 1 and trim(last[1] or "") == "." and entry.signature_rows[#entry.signature_rows - 1] then
        last = entry.signature_rows[#entry.signature_rows - 1] or {}
      end
      tail_repeat_fields = #last
    end
  end

  return {
    repeat_mode = repeat_mode,
    tail_repeat_from_row = tail_repeat_from_row,
    tail_repeat_fields = tail_repeat_fields,
    repeat_group_rows = (repeat_mode == "group_repeat" and entry and #(entry.signature_rows or {}) or nil),
    group_optional_first_row = (kw == "*MERGE"),
    optional_rows = optional_rows,
  }
end

function M.is_valid_data_line(keyword, row_index, line, entry)
  local kw = normalize_keyword(keyword)
  local fields = split_csv_keep_empty(line)
  local row_spec = nil

  if entry and entry.signature_rows and entry.signature_rows[row_index] then
    row_spec = entry.signature_rows[row_index]
  elseif entry and entry.signature_rows and entry.signature_rows[#entry.signature_rows] then
    row_spec = entry.signature_rows[#entry.signature_rows]
  end

  if row_spec and type(row_spec) == "table" and #row_spec > 0 then
    local is_repeat_dot = (#row_spec == 1 and trim(row_spec[1] or "") == ".")
    if not is_repeat_dot and #fields < #row_spec then
      for i = #fields + 1, #row_spec do
        fields[i] = ""
      end
    end
  end

  if kw == "*ACTIVATE_ELEMENTS" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 6
        and is_blank_or_expr(fields[1])
        and in_set(fields[2], { "ES", "G", "GS", "P", "PS" })
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and is_blank_or_expr(fields[6])
    end
  end

  if kw == "*ADD_MASS" then
    return #fields == 5
      and is_int_token(fields[1])
      and in_set(fields[2], { "N", "G", "P", "PS" })
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and in_set(fields[5], { "0", "1", "2", "3" })
  end

  if kw == "*BALANCE_SURFACE_MASS" then
    return #fields == 5
      and is_int_token(fields[1])
      and in_set(fields[2], { "P", "PS" })
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
  end

  if kw == "*NODE" then
    if #fields ~= 4 then
      return false
    end
    return is_int_token(fields[1])
      and is_real_token(fields[2])
      and is_real_token(fields[3])
      and is_real_token(fields[4])
  end

  if kw == "*PARAMETER" or kw == "*PARAMETER_DEFAULT" then
    local left, right = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
    if not left or not right or trim(left) == "" or trim(right) == "" then
      return false
    end
    local expr = trim((right:match("^(.-),%s*\"") or right:match("^([^,]+)") or right))
    return is_identifier_name(left) and is_simple_expr(expr)
  end

  if kw == "*PARAMETER_RANGE_BOOL" then
    return #fields == 1 and is_int_token(fields[1])
  end

  if kw == "*PARAMETER_RANGE_CONTINUOUS" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 3 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*PARAMETER_RANGE_DISCRETE" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index >= 2 then
      return #fields == 2
        and is_blank_or_expr(fields[1])
        and (is_quoted_string(fields[2]) or trim(fields[2]) ~= "")
    end
  end

  if kw == "*PART" then
    if #fields < 1 or #fields > 8 then
      return false
    end
    if not is_numericish_expr(fields[1]) then
      return false
    end
    return (#fields < 2 or is_numericish_expr(fields[2]))
      and (#fields < 3 or trim(fields[3]) == "" or trim(fields[3]) == "-")
      and (#fields < 4 or is_blank_or_expr(fields[4]))
      and (#fields < 5 or is_blank_or_expr(fields[5]))
      and (#fields < 6 or is_blank_or_expr(fields[6]))
      and (#fields < 7 or is_blank_or_expr(fields[7]))
      and (#fields < 8 or is_blank_or_expr(fields[8]))
  end

  if kw:match("^%*SET_") then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if kw == "*SET_FACE" then
      return #fields == 4 and all_fields_match(fields, is_int_token)
    end
    return #fields >= 1 and #fields <= 8 and all_fields_match(fields, is_set_range_token)
  end

  if kw:match("^%*ELEMENT_") then
    if entry and entry.signature_rows and entry.signature_rows[1] then
      local expected = #(entry.signature_rows[1] or {})
      return #fields == expected and all_fields_match(fields, is_int_token)
    end
    return #fields >= 3 and all_fields_match(fields, is_int_token)
  end

  if kw == "*BC_MOTION" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      if #fields < 3 or #fields > 8 then
        return false
      end
      return in_set(fields[1], { "N", "NS", "P", "PS", "ALL", "G", "GS" })
        and is_blank_or_expr(fields[2])
        and in_set(fields[3], { "0", "X", "Y", "Z", "XY", "YZ", "ZX", "XYZ" })
        and (trim(fields[4] or "") == "" or in_set(fields[4], { "0", "X", "Y", "Z", "XY", "YZ", "ZX", "XYZ" }))
        and (#fields < 5 or is_blank_or_expr(fields[5]))
        and (#fields < 6 or is_blank_or_expr(fields[6]))
        and (#fields < 7 or is_blank_or_expr(fields[7]))
        and (#fields < 8 or is_blank_or_expr(fields[8]))
    end
    if row_index >= 3 then
      if #fields < 2 or #fields > 5 then
        return false
      end
      return in_set(fields[1], { "A", "V", "D", "" })
        and trim(fields[2]) ~= ""
        and (#fields < 3 or is_blank_or_expr(fields[3]))
        and (#fields < 4 or is_blank_or_expr(fields[4]))
        and (#fields < 5 or is_blank_or_expr(fields[5]))
    end
  end

  if kw == "*BC_PERIODIC" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 4
        and in_set(fields[1], { "G", "GS", "NS", "FS" })
        and is_blank_or_expr(fields[2])
        and in_set(fields[3], { "G", "GS", "NS", "FS" })
        and is_blank_or_expr(fields[4])
    end
  end

  if kw == "*BC_SYMMETRY" then
    return #fields == 5
      and in_set(fields[1], { "0", "X", "Y", "Z", "XY", "YZ", "ZX", "XYZ" })
      and is_blank_or_expr(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
  end

  if kw == "*BC_TELEPORT" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 6
        and in_set(fields[1], { "P", "PS" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and in_set(fields[5], { "0", "1" })
        and in_set(fields[6], { "0", "1" })
    end
    if row_index == 3 then
      return #fields == 9 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*BC_TEMPERATURE" then
    return #fields == 6
      and in_set(fields[1], { "G", "P", "PS" })
      and is_blank_or_expr(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
      and is_blank_or_expr(fields[6])
  end

  if kw == "*BOLT_FAILURE" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 5 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*CHANGE_P-ORDER" then
    if #fields == 3 then
      return in_set(fields[1], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[2])
        and in_set(fields[3], { "1", "2", "3" })
    end
    if #fields == 4 then
      return in_set(fields[1], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[2])
        and in_set(fields[3], { "1", "2", "3" })
        and is_blank_or_expr(fields[4])
    end
    return false
  end

  if kw == "*CHANGE_PART_ID" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 3
        and is_blank_or_expr(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
    end
  end

  if kw == "*SMOOTH_MESH" then
    -- *SMOOTH_MESH: non-repeating keyword with 1-2 rows
    -- Row 1: entype, enid, α_max, [internal], [gid] (data row)
    -- Row 2: optional csysid
    if row_index == 1 then
      -- Allow 3-5 fields for data row
      return #fields >= 3 and #fields <= 5
    end
    if row_index == 2 then
      -- Optional csysid: 0 or 1 field
      return #fields <= 1
    end
    -- Only 2 rows maximum
    return false
  end

  if kw == "*INCLUDE" then
    if row_index == 1 then
      return is_path_like(line)
    end
    if row_index == 2 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 3 then
      return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 4 then
      return #fields == 7 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*CURVE" then
    if row_index == 1 then
      if #fields ~= 5 then
        return false
      end
      return is_int_token(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and in_set(fields[4], { "TIME", "LENGTH", "DISP", "VELO", "ACC", "FORCE", "STRESS", "STRAIN", "PRESSURE", "TEMP", "ENERGY", "NONE" })
        and in_set(fields[5], { "TIME", "LENGTH", "DISP", "VELO", "ACC", "FORCE", "STRESS", "STRAIN", "PRESSURE", "TEMP", "ENERGY", "NONE" })
    end
    if row_index >= 2 then
      return #fields == 2 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*SCRIPT_PYTHON" then
    return row_index == 1 and is_path_like(line)
  end

  if kw:match("^%*GEOMETRY_") then
    if kw == "*GEOMETRY_COMPOSITE" then
      if row_index == 1 then
        return #fields == 1 and is_int_token(fields[1])
      end
      if row_index >= 2 then
        return #fields >= 1 and #fields <= 8 and all_fields_match(fields, is_int_token)
      end
    elseif kw == "*GEOMETRY_PART" then
      if row_index == 1 then
        return #fields == 1 and is_int_token(fields[1])
      end
      if row_index == 2 then
        return #fields == 1 and is_blank_or_expr(fields[1])
      end
    elseif kw == "*GEOMETRY_SEED_COORDINATE" then
      if row_index == 1 then
        return #fields == 1 and is_int_token(fields[1])
      end
      if row_index == 2 then
        return #fields == 5 and all_fields_match(fields, is_blank_or_expr)
      end
    elseif kw == "*GEOMETRY_SEED_NODE" then
      if row_index == 1 then
        return #fields == 1 and is_int_token(fields[1])
      end
      if row_index == 2 then
        return #fields == 3 and all_fields_match(fields, is_blank_or_expr)
      end
    elseif kw == "*GEOMETRY_BOX" or kw == "*GEOMETRY_ELLIPSOID" or kw == "*GEOMETRY_SPHERE" then
      if row_index == 1 then
        return #fields == 2 and is_int_token(fields[1]) and is_blank_or_expr(fields[2])
      end
      if row_index == 2 then
        return #fields >= 5 and #fields <= 6 and all_fields_match(fields, is_blank_or_expr)
      end
    elseif kw == "*GEOMETRY_EFP" then
      if row_index == 1 then
        return #fields == 2 and is_int_token(fields[1]) and is_blank_or_expr(fields[2])
      end
      if row_index == 2 then
        return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
      end
      if row_index == 3 then
        return #fields == 1 and is_blank_or_expr(fields[1])
      end
    elseif kw == "*GEOMETRY_PIPE" then
      if row_index == 1 then
        return #fields == 2 and is_int_token(fields[1]) and is_blank_or_expr(fields[2])
      end
      if row_index == 2 then
        return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
      end
      if row_index == 3 then
        return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
      end
    end
  end

  if kw:match("^%*COORDINATE_SYSTEM") then
    return #fields >= 2 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw == "*COMPONENT_BOX" then
    if row_index == 1 then
      return #fields >= 5 and #fields <= 6
        and is_blank_or_expr(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and (#fields < 6 or is_blank_or_expr(fields[6]))
    end
    if row_index == 2 then
      return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*COMPONENT_BOX_IRREGULAR" then
    if row_index == 1 then
      return #fields == 3
        and is_blank_or_expr(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
    end
    if row_index >= 2 and row_index <= 9 then
      return #fields == 3 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*COMPONENT_SPHERE" then
    if row_index == 1 then
      return #fields >= 3 and #fields <= 6
        and is_blank_or_expr(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and (#fields < 4 or is_blank_or_expr(fields[4]))
        and (#fields < 5 or is_blank_or_expr(fields[5]))
        and (#fields < 6 or is_blank_or_expr(fields[6]))
    end
    if row_index == 2 then
      return (#fields == 4 or #fields == 5) and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*COMPONENT_REBAR" then
    if row_index == 1 then
      return #fields == 2 and is_blank_or_expr(fields[1]) and is_blank_or_expr(fields[2])
    end
    if row_index == 2 then
      return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*COMPONENT_BOLT" then
    if row_index == 1 then
      return #fields == 7 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 2 then
      return #fields == 4 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*COMPONENT_CYLINDER" then
    if row_index == 1 then
      return #fields == 6
        and is_blank_or_expr(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and (trim(fields[6] or "") == "" or in_set(fields[6], { "0", "1", "2" }))
    end
    if row_index == 2 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*COMPONENT_PIPE" then
    if row_index == 1 then
      return #fields == 8
        and is_blank_or_expr(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and is_blank_or_expr(fields[6])
        and is_blank_or_expr(fields[7])
        and is_blank_or_expr(fields[8])
    end
    if row_index == 2 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 3 then
      return #fields == 2 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*DEFINE_ELEMENT_SET" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 4
        and in_set(fields[1], { "P", "PS" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
    end
  end

  if kw == "*DETONATION" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields >= 5 and #fields <= 8 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*END" then
    return trim(line) == ""
  end

  if kw == "*EOS_GRUNEISEN" then
    return #fields >= 1 and #fields <= 4
      and is_int_token(fields[1])
      and (#fields < 2 or is_blank_or_expr(fields[2]))
      and (#fields < 3 or is_blank_or_expr(fields[3]))
      and (#fields < 4 or is_blank_or_expr(fields[4]))
  end

  if kw == "*EOS_TAIT" then
    return #fields == 2
      and is_int_token(fields[1])
      and is_blank_or_expr(fields[2])
  end

  if kw == "*EROSION_CRITERION" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 9
        and in_set(fields[1], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and is_blank_or_expr(fields[6])
        and in_set(fields[7], { "0", "1", "2", "3", "4" })
        and is_blank_or_expr(fields[8])
        and is_blank_or_expr(fields[9])
    end
  end

  if kw == "*EROSION_CRITERION_SPH_DRIVEN" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 4
        and is_int_token(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
    end
  end

  if kw == "*FRAGMENT_CLEANUP" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 4
        and is_int_token(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
    end
  end

  if kw == "*FREQUENCY_CUTOFF" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 7
        and in_set(fields[1], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and is_blank_or_expr(fields[6])
        and in_set(fields[7], { "0", "1" })
    end
  end

  if kw == "*GENERATE_COMPONENT_DISTRIBUTION" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 4
        and is_blank_or_expr(fields[1])
        and in_set(fields[2], { "1" })
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
    end
  end

  if kw == "*GENERATE_PARTICLE_DISTRIBUTION" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields >= 1 and #fields <= 6 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 3 then
      return #fields >= 1 and #fields <= 2 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*MAT_RIGID" then
    if #fields < 2 or #fields > 6 then
      return false
    end
    return is_blank_or_expr(fields[1])
      and is_blank_or_expr(fields[2])
      and (#fields < 3 or trim(fields[3]) == "" or trim(fields[3]) == "-")
      and (#fields < 4 or trim(fields[4]) == "" or trim(fields[4]) == "-")
      and (#fields < 5 or trim(fields[5]) == "" or trim(fields[5]) == "-")
      and (#fields < 6 or is_blank_or_expr(fields[6]))
  end

  if kw == "*MERGE" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 10
        and in_set(fields[1], { "G", "NS", "P", "PS", "SPH" })
        and is_blank_or_expr(fields[2])
        and in_set(fields[3], { "G", "P", "PS" })
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and is_blank_or_expr(fields[6])
        and is_blank_or_expr(fields[7])
        and in_set(fields[8], { "0", "1" })
        and is_blank_or_expr(fields[9])
        and in_set(fields[10], { "0", "1" })
    end
  end

  if kw == "*MERGE_DUPLICATED_NODES" then
    return #fields == 6
      and in_set(fields[1], { "P", "PS" })
      and is_blank_or_expr(fields[2])
      and in_set(fields[3], { "P", "PS" })
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
      and in_set(fields[6], { "0", "1" })
  end

  if kw == "*MERGE_FAILURE_BOLT" or kw == "*MERGE_FAILURE_FORCE" then
    return #fields == 5
      and is_int_token(fields[1])
      and all_fields_match({ fields[2], fields[3], fields[4], fields[5] }, is_blank_or_expr)
  end

  if kw == "*MERGE_FAILURE_COHESIVE" then
    return #fields == 6
      and is_int_token(fields[1])
      and all_fields_match({ fields[2], fields[3], fields[4], fields[5], fields[6] }, is_blank_or_expr)
  end

  if kw == "*OBJECT" then
    if row_index == 1 then
      return #fields == 3
        and trim(fields[1]) ~= ""
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
    end
    if row_index == 2 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 3 or row_index == 4 then
      return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index >= 5 then
      if #fields < 1 or #fields > 2 then
        return false
      end
      local left, right = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
      if #fields == 1 then
        return left ~= nil and is_identifier_name(left) and is_simple_expr(right or "")
      end
      local name, value = trim(fields[1]):match("^(.-)%s*=%s*(.-)$")
      return name ~= nil
        and is_identifier_name(name)
        and is_simple_expr(value or "")
        and trim(fields[2]) ~= ""
    end
  end

  if kw == "*OUTPUT" then
    if row_index == 1 then
      return #fields == 4
        and is_blank_or_expr(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and in_set(fields[4], { "0", "1", "2", "3" })
    end
    if row_index == 2 then
      return #fields == 5
        and in_set(fields[1], { "0", "1", "2" })
        and in_set(fields[2], { "0", "1", "2" })
        and in_set(fields[3], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
    end
  end

  if kw == "*LOAD_AIR_BLAST" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 8
        and in_set(fields[1], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[2])
        and all_fields_match(vim.list_slice(fields, 3, 7), is_blank_or_expr)
        and in_set(fields[8], { "0", "1", "2" })
    end
    if row_index == 3 then
      return #fields == 3
        and in_set(fields[1], { "0", "1" })
        and (trim(fields[2]) == "" or in_set(fields[2], { "X", "Y", "Z" }))
        and is_blank_or_expr(fields[3])
    end
  end

  if kw == "*LOAD_CENTRIFUGAL" then
    return #fields == 6
      and in_set(fields[1], { "N", "NS", "P", "PS" })
      and is_blank_or_expr(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
      and is_blank_or_expr(fields[6])
  end

  if kw == "*LOAD_DAMPING" then
    return #fields == 7
      and in_set(fields[1], { "N", "NS", "P", "PS", "ALL", "SPH" })
      and is_blank_or_expr(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
      and is_blank_or_expr(fields[6])
      and is_blank_or_expr(fields[7])
  end

  if kw == "*LOAD_ELEMENT_SMOOTHING" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 3
        and in_set(fields[1], { "P", "PS", "G", "GS", "FS", "ALL" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
    end
  end

  if kw == "*LOAD_EM_CABLE" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 4 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*MAP" then
    if row_index == 1 then
      return #fields >= 3 and #fields <= 4 and all_fields_match(fields, function(v)
        return is_int_token(v) or is_blank_or_expr(v)
      end)
    end
    return #fields >= 1 and #fields <= 8 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw == "*IB_CONTROL" or kw == "*IB_INHIBITION" then
    return #fields >= 1 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw == "*INITIAL_DISPLACEMENT" then
    return #fields == 5
      and in_set(fields[1], { "N", "P" })
      and is_blank_or_expr(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
  end

  if kw == "*INITIAL_CONTACT" then
    return #fields == 11
      and all_fields_match({ fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7] }, is_int_token)
      and is_blank_or_expr(fields[8])
      and is_blank_or_expr(fields[9])
      and is_blank_or_expr(fields[10])
      and is_blank_or_expr(fields[11])
  end

  if kw == "*INITIAL_DAMAGE_MAP" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 9
        and in_set(fields[1], { "P", "PS" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and is_blank_or_expr(fields[6])
        and is_blank_or_expr(fields[7])
        and is_blank_or_expr(fields[8])
        and is_blank_or_expr(fields[9])
    end
    if row_index == 3 then
      return #fields == 7
        and all_fields_match(vim.list_slice(fields, 1, 6), is_blank_or_expr)
        and in_set(fields[7], { "0", "1" })
    end
  end

  if kw == "*INITIAL_DAMAGE_RANDOM" then
    return #fields == 8
      and in_set(fields[1], { "M", "P", "PS" })
      and is_blank_or_expr(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
      and is_blank_or_expr(fields[6])
      and is_blank_or_expr(fields[7])
      and is_blank_or_expr(fields[8])
  end

  if kw == "*INITIAL_DAMAGE_SURFACE_RANDOM" then
    return #fields >= 6 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw == "*INITIAL_TEMPERATURE" then
    return #fields == 4
      and in_set(fields[1], { "N", "P", "PS", "ALL" })
      and is_blank_or_expr(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
  end

  if kw == "*INITIAL_THICKNESS" then
    return #fields == 2 and is_int_token(fields[1]) and is_blank_or_expr(fields[2])
  end

  if kw == "*INITIAL_VELOCITY" then
    if row_index == 1 then
      return #fields == 8
        and in_set(fields[1], { "N", "NS", "P", "PS", "ALL", "G", "DP", "SPH" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and is_blank_or_expr(fields[6])
        and is_blank_or_expr(fields[7])
        and is_blank_or_expr(fields[8])
    end
    if row_index == 2 then
      return #fields == 7 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*INITIAL_FACE_DATA" then
    return #fields == 8
      and is_int_token(fields[1])
      and is_int_token(fields[2])
      and is_int_token(fields[3])
      and is_int_token(fields[4])
      and is_blank_or_expr(fields[5])
      and is_blank_or_expr(fields[6])
      and is_blank_or_expr(fields[7])
      and is_blank_or_expr(fields[8])
  end

  if kw == "*INITIAL_MATERIAL_DIRECTION" then
    return #fields == 7
      and is_int_token(fields[1])
      and all_fields_match({ fields[2], fields[3], fields[4], fields[5], fields[6], fields[7] }, is_blank_or_expr)
  end

  if kw == "*INITIAL_MATERIAL_DIRECTION_PATH" then
    return #fields == 4
      and is_int_token(fields[1])
      and in_set(fields[2], { "P", "PS" })
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
  end

  if kw == "*INITIAL_MATERIAL_DIRECTION_VECTOR" then
    if row_index == 1 then
      return #fields == 3
        and is_int_token(fields[1])
        and in_set(fields[2], { "P", "PS" })
        and is_blank_or_expr(fields[3])
    end
    if row_index == 2 then
      return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*INITIAL_MATERIAL_DIRECTION_WRAP" then
    if row_index == 1 then
      return #fields == 3
        and is_int_token(fields[1])
        and in_set(fields[2], { "P", "PS" })
        and is_blank_or_expr(fields[3])
    end
    if row_index == 2 then
      return #fields == 7 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*INITIAL_PLASTIC_STRAIN_FUNCTION" then
    return #fields == 5
      and is_int_token(fields[1])
      and in_set(fields[2], { "P", "PS", "G", "ALL" })
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and in_set(fields[5], { "0", "1" })
  end

  if kw == "*INITIAL_STATE" then
    if row_index == 1 then
      return #fields == 5 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index >= 2 and row_index <= 4 then
      return #fields == 3 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 5 or row_index == 6 then
      return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index >= 7 and row_index <= 9 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*INITIAL_STRESS_FUNCTION" then
    if row_index == 1 then
      return #fields == 8
        and in_set(fields[1], { "M", "P", "PS", "SPH", "RB" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and is_blank_or_expr(fields[6])
        and is_blank_or_expr(fields[7])
        and is_blank_or_expr(fields[8])
    end
    if row_index == 2 then
      return #fields == 1 and in_set(fields[1], { "0", "1", "2" })
    end
  end

  if kw == "*INITIAL_STATE_HAZ" then
    return #fields == 6
      and in_set(fields[1], { "P", "PS", "PATH" })
      and is_blank_or_expr(fields[2])
      and in_set(fields[3], { "P", "PS" })
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
      and is_blank_or_expr(fields[6])
  end

  if kw == "*CONTACT" then
    if row_index == 1 then
      return #fields == 3
        and is_int_token(fields[1])
        and is_int_token(fields[2])
        and is_int_token(fields[3])
    end
    if row_index == 2 then
      return #fields == 8
        and in_set(fields[1], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[2])
        and in_set(fields[3], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and is_blank_or_expr(fields[6])
        and is_blank_or_expr(fields[7])
        and is_blank_or_expr(fields[8])
    end
    if row_index == 3 then
      return #fields == 7 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 4 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*CONTACT_ACCURACY" then
    return #fields >= 1 and #fields <= 3 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw == "*CONTACT_REBAR" then
    if row_index == 1 then
      return #fields == 2 and is_int_token(fields[1]) and is_blank_or_expr(fields[2])
    end
    if row_index == 2 then
      return #fields == 3
        and in_set(fields[1], { "P", "PS" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
    end
  end

  if kw == "*FUNCTION" then
    if row_index == 1 then
      -- Support both the full 6-field FUNCTION header and the compact
      -- common form:
      --   *FUNCTION
      --   "title"
      --   111
      --   SC_jet(1)
      if #fields == 1 then
        return is_int_token(fields[1]) or is_blank_or_expr(fields[1])
      end
      if #fields ~= 6 then
        return false
      end
      return is_int_token(fields[1])
        and is_int_token(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and in_set(fields[5], { "TIME", "STRAIN", "NONE" })
        and in_set(fields[6], { "TIME", "DISP", "LENGTH", "VELO", "ACC", "FORCE", "STRESS", "STRAIN", "PRESSURE", "TEMP", "ENERGY", "NONE" })
    end
    if row_index == 2 then
      return trim(line) ~= ""
    end
  end

  if kw == "*OUTPUT_ELEMENT" then
    return #fields == 2
      and in_set(fields[1], { "E", "ES" })
      and is_blank_or_expr(fields[2])
  end

  if kw == "*OUTPUT_CONTACT_FORCE" then
    return #fields == 3
      and is_int_token(fields[1])
      and in_set(fields[2], { "P", "PS", "G", "ALL" })
      and is_blank_or_expr(fields[3])
  end

  if kw == "*OUTPUT_DAMAGE_MAP" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 5
        and is_blank_or_expr(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
    end
    if row_index == 3 then
      return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*OUTPUT_DEBUG" then
    return #fields == 1 or trim(line) ~= ""
  end

  if kw == "*OUTPUT_ERROR" then
    return #fields == 1 or trim(line) ~= ""
  end

  if kw == "*OUTPUT_FORMING" then
    return #fields == 1 and in_set(fields[1], { "0", "1" })
  end

  if kw == "*OUTPUT_NODE" then
    return #fields == 2
      and in_set(fields[1], { "N", "NS" })
      and is_blank_or_expr(fields[2])
  end

  if kw == "*OUTPUT_SENSOR" then
    return #fields == 9
      and is_int_token(fields[1])
      and is_blank_or_expr(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
      and is_blank_or_expr(fields[6])
      and is_blank_or_expr(fields[7])
      and is_blank_or_expr(fields[8])
      and is_blank_or_expr(fields[9])
  end

  if kw == "*OUTPUT_SENSOR_EXTENDED" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index >= 2 then
      return #fields >= 3
        and is_int_token(fields[1])
        and is_int_token(fields[2])
        and all_fields_match(vim.list_slice(fields, 3), is_blank_or_expr)
    end
  end

  if kw == "*OUTPUT_SENSOR_PATH" then
    return #fields == 4
      and is_int_token(fields[1])
      and is_blank_or_expr(fields[2])
      and is_blank_or_expr(fields[3])
      and is_int_token(fields[4])
  end

  if kw:match("^%*PARTICLE_") then
    if kw == "*PARTICLE_AIR" then
      if row_index == 1 then
        return #fields == 2 and is_int_token(fields[1]) and is_blank_or_expr(fields[2])
      end
      if row_index == 2 then
        return #fields == 8
          and in_set(fields[1], { "AIR", "VOID", "USER" })
          and all_fields_match({ fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8] }, is_blank_or_expr)
      end
      if row_index == 3 then
        return #fields == 4 and all_fields_match(fields, is_blank_or_expr)
      end
    end

    if kw == "*PARTICLE_DETONATION" then
      if row_index == 1 then
        return #fields == 1 and is_int_token(fields[1])
      end
      if row_index == 2 then
        return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
      end
    end

    if kw == "*PARTICLE_DOMAIN" then
      if row_index == 1 then
        return #fields >= 1 and #fields <= 8
          and in_set(fields[1], { "P", "PS", "ALL" })
          and (#fields < 2 or is_blank_or_expr(fields[2]))
          and (#fields < 3 or is_blank_or_expr(fields[3]))
          and (#fields < 4 or is_blank_or_expr(fields[4]))
          and (#fields < 5 or is_blank_or_expr(fields[5]))
          and (#fields < 6 or is_blank_or_expr(fields[6]))
          and (#fields < 7 or is_blank_or_expr(fields[7]))
          and (#fields < 8 or is_blank_or_expr(fields[8]))
      end
      if row_index == 2 or row_index == 3 then
        return #fields >= 1 and #fields <= 6 and all_fields_match(fields, is_blank_or_expr)
      end
      if row_index == 4 then
        return #fields >= 1 and #fields <= 3
          and (#fields < 1 or is_blank_or_expr(fields[1]))
          and (#fields < 2 or in_set(fields[2], { "0", "1" }))
          and (#fields < 3 or in_set(fields[3], { "0", "1" }))
      end
    end

    if kw == "*PARTICLE_DOMAIN_CLEANUP" then
      if row_index == 1 then
        return #fields == 7
          and is_int_token(fields[1])
          and is_blank_or_expr(fields[2])
          and is_blank_or_expr(fields[3])
          and in_set(fields[4], { "0", "1" })
          and is_blank_or_expr(fields[5])
          and is_blank_or_expr(fields[6])
          and is_blank_or_expr(fields[7])
      end
      if row_index == 2 then
        return #fields == 3 and all_fields_match(fields, is_blank_or_expr)
      end
    end

    if kw == "*PARTICLE_HE" then
      if row_index == 1 then
        return #fields == 2 and is_int_token(fields[1]) and is_blank_or_expr(fields[2])
      end
      if row_index == 2 then
        return #fields == 8
          and trim(fields[1]) ~= ""
          and is_blank_or_expr(fields[2])
          and in_set(fields[3], { "0", "1" })
          and all_fields_match({ fields[4], fields[5], fields[6], fields[7], fields[8] }, is_blank_or_expr)
      end
      if row_index == 3 then
        return #fields == 5 and all_fields_match(fields, is_blank_or_expr)
      end
    end

    if kw == "*PARTICLE_SOIL" then
      if row_index == 1 then
        return #fields == 2 and is_int_token(fields[1]) and is_blank_or_expr(fields[2])
      end
      if row_index == 2 then
        return #fields == 8
          and in_set(fields[1], { "DRY", "WET", "USER" })
          and all_fields_match({ fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8] }, is_blank_or_expr)
      end
      if row_index == 3 then
        return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
      end
    end

    if kw == "*PARTICLE_SPH" then
      if row_index == 1 then
        return #fields == 2 and is_int_token(fields[1]) and is_blank_or_expr(fields[2])
      end
      if row_index == 2 then
        return #fields == 8
          and is_int_token(fields[1])
          and is_blank_or_expr(fields[2])
          and in_set(fields[3], { "0", "1", "2" })
          and is_blank_or_expr(fields[4])
          and is_blank_or_expr(fields[5])
          and in_set(fields[6], { "0", "1" })
          and in_set(fields[7], { "0", "1" })
          and is_blank_or_expr(fields[8])
      end
      if row_index == 3 then
        return #fields == 1 and is_blank_or_expr(fields[1])
      end
    end

    if kw == "*PARTICLE_SPH_JET" then
      if row_index == 1 then
        return #fields == 1 and is_int_token(fields[1])
      end
      if row_index == 2 then
        return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
      end
      if row_index == 3 then
        return #fields == 3
          and is_blank_or_expr(fields[1])
          and is_blank_or_expr(fields[2])
          and in_set(fields[3], { "0", "1" })
      end
    end

    if kw == "*PARTICLE_SPH_JET_LSC" then
      if row_index == 1 then
        return #fields == 1 and is_int_token(fields[1])
      end
      if row_index == 2 then
        return #fields == 5 and all_fields_match(fields, is_blank_or_expr)
      end
      if row_index == 3 or row_index == 4 then
        return #fields == 3 and all_fields_match(fields, is_blank_or_expr)
      end
    end
  end

  if kw == "*PATH" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    return #fields == 3 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw == "*PETRIFY" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 5
        and in_set(fields[1], { "P", "PS" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and in_set(fields[5], { "0", "1" })
    end
  end

  if kw == "*POWDER_BURN_IGNITE" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*POWDER_BURN_SHAPE_FUNCTION" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 2 and is_int_token(fields[1]) and is_blank_or_expr(fields[2])
    end
  end

  if kw == "*PRESTRESS_BLIND_HOLE_BOLT" then
    return #fields == 6
      and is_int_token(fields[1])
      and is_int_token(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
      and is_blank_or_expr(fields[6])
  end

  if kw == "*PRESTRESS_BOLT" then
    return #fields == 7
      and is_int_token(fields[1])
      and is_int_token(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
      and is_blank_or_expr(fields[6])
      and in_set(fields[7], { "0", "1" })
  end

  if kw == "*OUTPUT_SENSOR_THICKNESS" then
    if row_index == 1 then
      return #fields == 8
        and is_int_token(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and in_set(fields[6], { "0", "1" })
        and is_blank_or_expr(fields[7])
        and is_blank_or_expr(fields[8])
    end
    if row_index == 2 then
      return #fields == 3 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*OUTPUT_USER" then
    return #fields == 4
      and is_int_token(fields[1])
      and is_quoted_string(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
  end

  if kw == "*OUTPUT_USER_COLLECTION" then
    if row_index == 1 then
      return #fields == 3
        and is_int_token(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
    end
    if row_index == 2 then
      return #fields == 5
        and in_set(fields[1], { "N", "NS", "P", "PS", "G", "ALL", "E", "ES" })
        and is_blank_or_expr(fields[2])
        and in_set(fields[3], { "N", "E" })
        and is_blank_or_expr(fields[4])
        and in_set(fields[5], { "0", "1" })
    end
  end

  if kw == "*OUTPUT_J_INTEGRAL" then
    return #fields == 6
      and is_int_token(fields[1])
      and in_set(fields[2], { "P", "PS", "ALL" })
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
      and is_blank_or_expr(fields[6])
  end

  if kw == "*OUTPUT_SECTION" then
    return #fields == 5
      and is_int_token(fields[1])
      and in_set(fields[2], { "P", "PS", "ALL" })
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
  end

  if kw == "*MAT_METAL" then
    if row_index == 1 then
      if #fields ~= 7 then
        return false
      end
      return is_int_token(fields[1]) and all_fields_match({ fields[2], fields[3], fields[4], fields[5], fields[6], fields[7] }, is_blank_or_expr)
    end
    if row_index == 2 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 3 then
      return #fields == 4 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*MAT_OBJECT" then
    if #fields < 1 or #fields > 2 then
      return false
    end
    local left, right = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
    if #fields == 1 then
      return left ~= nil and is_identifier_name(left) and is_simple_expr(right or "")
    end
    local name, value = trim(fields[1]):match("^(.-)%s*=%s*(.-)$")
    return name ~= nil
      and is_identifier_name(name)
      and is_simple_expr(value or "")
      and (is_quoted_string(fields[2]) or trim(fields[2]) ~= "")
  end

  if kw == "*MAT_USER_X" then
    if row_index == 1 then
      return #fields == 7
        and is_int_token(fields[1])
        and all_fields_match({ fields[2], fields[3], fields[4], fields[5], fields[6], fields[7] }, is_blank_or_expr)
    end
    if row_index >= 2 and row_index <= 8 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*MAT_JC" then
    if row_index == 1 then
      return #fields == 7
        and is_int_token(fields[1])
        and all_fields_match({ fields[2], fields[3], fields[4], fields[5], fields[6], fields[7] }, is_blank_or_expr)
    end
    if row_index == 2 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 3 then
      return #fields == 4
        and (trim(fields[1]) == "" or trim(fields[1]) == "-")
        and (trim(fields[2]) == "" or trim(fields[2]) == "-")
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
    end
  end

  if kw == "*MAT_JC_FIELD" then
    if row_index == 1 then
      return #fields == 4
        and is_int_token(fields[1])
        and all_fields_match({ fields[2], fields[3], fields[4] }, is_blank_or_expr)
    end
    if row_index == 2 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 3 then
      return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*MAT_JH_CERAMIC" then
    if row_index == 1 then
      return #fields == 3
        and is_int_token(fields[1])
        and all_fields_match({ fields[2], fields[3] }, is_blank_or_expr)
    end
    if row_index == 2 then
      return #fields == 7 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 3 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 4 then
      return #fields == 1 and in_set(fields[1], { "0", "1" })
    end
  end

  if kw == "*MAT_LEE_TARVER" then
    if row_index == 1 then
      return #fields == 3
        and is_int_token(fields[1])
        and all_fields_match({ fields[2], fields[3] }, is_blank_or_expr)
    end
    if row_index == 2 then
      return #fields == 10 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 3 then
      return #fields == 10 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 4 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 5 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 6 then
      return #fields == 3 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw:match("^%*MAT_") then
    return #fields >= 1 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw == "*CONNECTOR_DAMPER" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 8
        and is_blank_or_expr(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and is_blank_or_expr(fields[6])
        and is_blank_or_expr(fields[7])
        and is_blank_or_expr(fields[8])
    end
    if row_index == 3 then
      return #fields == 4 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*CONNECTOR_GLUE_LINE" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 8
        and in_set(fields[1], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[2])
        and in_set(fields[3], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and is_blank_or_expr(fields[6])
        and is_blank_or_expr(fields[7])
        and is_blank_or_expr(fields[8])
    end
    if row_index == 3 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*CONNECTOR_GLUE_SURFACE" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 5
        and in_set(fields[1], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[2])
        and in_set(fields[3], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
    end
    if row_index == 3 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*CONNECTOR_RIGID" then
    return #fields == 3
      and is_int_token(fields[1])
      and in_set(fields[2], { "NS", "G" })
      and is_blank_or_expr(fields[3])
  end

  if kw == "*CONNECTOR_SPOT_WELD" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 4
        and in_set(fields[1], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
    end
    if row_index == 3 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*CONNECTOR_SPOT_WELD_NODE" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 4
        and in_set(fields[1], { "N", "NS", "G", "GS" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
    end
  end

  if kw == "*CONNECTOR_SPR" or kw == "*CONNECTOR_SPRING" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 or row_index == 3 then
      return #fields >= 4 and #fields <= 8 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*COUPLING_REBAR" then
    return #fields >= 1 and #fields <= 4 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw:match("^%*LOAD_") then
    return #fields >= 1 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw:match("^%*PROP_") then
    return #fields >= 1 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw == "*CFD_BLAST_1D" then
    if row_index == 1 then
      return #fields == 4
        and is_int_token(fields[1])
        and in_set(fields[2], { "0", "1", "2" })
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
    end
    if row_index == 2 then
      return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 3 then
      return #fields == 5 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*CFD_DETONATION" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 7
        and is_blank_or_expr(fields[1])
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and in_set(fields[6], { "0", "1" })
        and is_blank_or_expr(fields[7])
    end
  end

  if kw == "*CFD_DOMAIN" then
    if row_index == 1 then
      return #fields == 2
        and is_int_token(fields[1])
        and is_blank_or_expr(fields[2])
    end
    if row_index == 2 then
      return (#fields == 8 or #fields == 10) and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 3 or row_index == 4 then
      return #fields == 6 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 5 then
      return #fields == 1 and is_blank_or_expr(fields[1])
    end
  end

  if kw == "*CFD_GAS" then
    if row_index == 1 then
      return #fields == 1 and is_blank_or_expr(fields[1])
    end
    if row_index == 2 then
      return #fields == 2
        and in_set(fields[1], { "AIR", "USER" })
        and is_blank_or_expr(fields[2])
    end
    if row_index == 3 then
      return #fields == 5 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*CFD_HE" then
    if row_index == 1 then
      return #fields == 1 and is_blank_or_expr(fields[1])
    end
    if row_index == 2 then
      return #fields == 3
        and in_set(fields[1], { "PRESET", "USER", "MID" })
        and is_blank_or_expr(fields[2])
        and in_set(fields[3], { "0", "1" })
    end
    if row_index == 3 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
    if row_index == 4 then
      return #fields == 3 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*CFD_SOURCE" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*CFD_STATE" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 8 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*CFD_STRUCTURE_INTERACTION" then
    if row_index == 1 then
      return #fields == 3
        and is_int_token(fields[1])
        and in_set(fields[2], { "0", "1" })
        and is_blank_or_expr(fields[3])
    end
    if row_index == 2 then
      return #fields == 5
        and in_set(fields[1], { "P", "PS", "ALL" })
        and is_blank_or_expr(fields[2])
        and in_set(fields[3], { "1", "2" })
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
    end
    if row_index == 3 then
      return #fields == 1 and is_blank_or_expr(fields[1])
    end
  end

  if kw == "*CFD_WIND_TUNNEL" then
    return #fields == 6
      and is_blank_or_expr(fields[1])
      and is_blank_or_expr(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
      and in_set(fields[6], { "0", "1" })
  end

  if kw == "*RANDOM_NUMBER_GENERATOR_SEED" then
    return #fields == 1 and is_int_token(fields[1])
  end

  if kw == "*REDISTRIBUTE_MESH_CARTESIAN" or kw == "*REFINE" or kw == "*REMAP" or kw == "*SUBDIVIDE_PART_THICKNESS" then
    return #fields >= 1 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw == "*RIGID_BODY_ADD_NODES" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 3
        and is_int_token(fields[1])
        and in_set(fields[2], { "N", "NS", "G", "GS" })
        and is_blank_or_expr(fields[3])
    end
  end

  if kw == "*RIGID_BODY_DAMPING" then
    return #fields == 5
      and is_int_token(fields[1])
      and is_int_token(fields[2])
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
  end

  if kw == "*RIGID_BODY_INERTIA" then
    if row_index == 1 then
      return #fields == 8
        and is_int_token(fields[1])
        and all_fields_match({ fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8] }, is_blank_or_expr)
    end
    if row_index == 2 then
      return #fields == 3 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*RIGID_BODY_JOINT" then
    if row_index == 1 then
      return #fields == 1 and is_int_token(fields[1])
    end
    if row_index == 2 then
      return #fields == 8
        and in_set(fields[1], { "P", "CR" })
        and is_blank_or_expr(fields[2])
        and in_set(fields[3], { "P", "CR" })
        and is_blank_or_expr(fields[4])
        and in_set(fields[5], { "X", "Y", "Z", "XY", "YZ", "ZX", "XYZ" })
        and in_set(fields[6], { "X", "Y", "Z", "XY", "YZ", "ZX", "XYZ" })
        and is_blank_or_expr(fields[7])
        and is_blank_or_expr(fields[8])
    end
    if row_index == 3 or row_index == 4 then
      return #fields == 9 and all_fields_match(fields, is_blank_or_expr)
    end
  end

  if kw == "*RIGID_BODY_MERGE" then
    return #fields == 1 and is_int_token(fields[1])
  end

  if kw == "*RIGID_BODY_UPDATE" then
    return #fields == 1 and in_set(fields[1], { "0", "1", "2" })
  end

  if kw == "*SMS" or kw == "*VAA" or kw == "*VELOCITY_CAP" or kw == "*WELD" then
    return #fields >= 1 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw == "*TIME" then
    return #fields >= 1 and #fields <= 6 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw == "*TRANSFORM_MESH_CYLINDRICAL" then
    return #fields == 8
      and is_int_token(fields[1])
      and in_set(fields[2], { "G", "GS", "P", "PS" })
      and is_blank_or_expr(fields[3])
      and is_blank_or_expr(fields[4])
      and is_blank_or_expr(fields[5])
      and is_blank_or_expr(fields[6])
      and is_blank_or_expr(fields[7])
      and is_blank_or_expr(fields[8])
  end

  if kw == "*TRIM" then
    if row_index == 1 then
      return #fields == 7
        and in_set(fields[1], { "P", "PS" })
        and is_blank_or_expr(fields[2])
        and is_blank_or_expr(fields[3])
        and is_blank_or_expr(fields[4])
        and is_blank_or_expr(fields[5])
        and is_blank_or_expr(fields[6])
        and is_blank_or_expr(fields[7])
    end
    return #fields == 3 and all_fields_match(fields, is_blank_or_expr)
  end

  if kw == "*UNIT_SYSTEM" then
    return #fields == 1 and trim(fields[1]) ~= ""
  end

  local generic_ok = validate_by_signature_row(fields, row_spec)
  if generic_ok ~= nil then
    return generic_ok
  end

  if row_spec then
    local last_used = 0
    for i, value in ipairs(fields or {}) do
      if trim(value or "") ~= "" then
        last_used = i
      end
    end
    local expected = #(row_spec or {})
    if expected > 0 and last_used > expected then
      return false
    end
  end

  return true
end

return M
