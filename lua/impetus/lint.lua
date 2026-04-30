local store = require("impetus.store")
local analysis = require("impetus.analysis")
local schema = require("impetus.schema")

local M = {}

local ns = vim.api.nvim_create_namespace("impetus-lint")

-- =====================================================================
-- Helpers
-- =====================================================================

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function count_csv_fields(line)
  local n = 0
  for _ in line:gmatch("[^,]+") do
    n = n + 1
  end
  return n
end

local function starts_with(s, p)
  return s:sub(1, #p) == p
end

local function to_number(v)
  local t = trim(v or "")
  if t == "" then
    return nil
  end
  local n = tonumber(t)
  if n then
    return n
  end
  -- Try scientific notation patterns that tonumber might miss
  if t:match("^[+-]?%d+%.?%d*[eE][+-]?%d+$") then
    return tonumber(t)
  end
  return nil
end

local function split_csv_keep_empty(line)
  local out = {}
  local s = (line or "") .. ","
  for part in s:gmatch("(.-),") do
    out[#out + 1] = trim(part)
  end
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
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
  return false
end

local function normalize_param_name(s)
  return (trim(s or ""):gsub("^%%", ""):gsub("^%[", ""):gsub("%]$", ""))
end

local function resolve_param_value(name, idx)
  local key = normalize_param_name(name)
  local defs = idx.params.defs[key]
  if not defs or #defs == 0 then
    return nil
  end
  local line = defs[1].line or ""
  local right = line:match("=%s*(.-)%s*$") or ""
  right = trim(right)
  -- Strip trailing comment
  right = right:match("^([^,]+)") or right
  right = trim(right)
  return to_number(right)
end

-- =====================================================================
-- Severity helpers
-- =====================================================================

local SEV = {
  ERROR = vim.diagnostic.severity.ERROR,
  WARNING = vim.diagnostic.severity.WARN,
  SUSPICION = vim.diagnostic.severity.HINT,
}

local function push_diagnostic(diagnostics, lnum, col, severity, message, end_col)
  local d = {
    lnum = lnum,
    col = col,
    severity = severity,
    message = message,
    source = "impetus",
  }
  if end_col then
    d.end_col = end_col
  end
  diagnostics[#diagnostics + 1] = d
end

-- =====================================================================
-- Physics sanity database
-- =====================================================================

local physics_ranges = {
  SI = {
    rho = { suspicion_below = 500, suspicion_above = 30000, typical_steel = 7850, unit = "kg/m³" },
    e = { suspicion_below = 1e7, suspicion_above = 1e13, typical_steel = 210e9, unit = "Pa" },
    length = { suspicion_below = 1e-9, suspicion_above = 1e4, unit = "m" },
    velocity = { suspicion_above = 1e4, unit = "m/s" },
    mass = { suspicion_above = 1e9, unit = "kg" },
  },
  MMTONS = {
    rho = { suspicion_below = 5e-10, suspicion_above = 3e-8, typical_steel = 7.85e-9, unit = "ton/mm³" },
    e = { suspicion_below = 10, suspicion_above = 1e7, typical_steel = 2.1e5, unit = "ton/(mm·s²)" },
    length = { suspicion_below = 1e-6, suspicion_above = 1e7, unit = "mm" },
    velocity = { suspicion_above = 1e7, unit = "mm/s" },
    mass = { suspicion_above = 1e6, unit = "ton" },
  },
  MMKGMS = {
    rho = { suspicion_below = 5e-7, suspicion_above = 3e-5, typical_steel = 7.85e-6, unit = "kg/mm³" },
    e = { suspicion_below = 0.01, suspicion_above = 1e4, typical_steel = 210, unit = "kg/(mm·ms²)" },
    length = { suspicion_below = 1e-6, suspicion_above = 1e7, unit = "mm" },
    velocity = { suspicion_above = 1e4, unit = "mm/ms" },
    mass = { suspicion_above = 1e9, unit = "kg" },
  },
  CMGS = {
    rho = { suspicion_below = 0.5, suspicion_above = 30, typical_steel = 7.85, unit = "g/cm³" },
    e = { suspicion_below = 1e8, suspicion_above = 1e14, typical_steel = 2.1e12, unit = "dyne/cm²" },
    length = { suspicion_below = 1e-7, suspicion_above = 1e6, unit = "cm" },
    velocity = { suspicion_above = 1e6, unit = "cm/s" },
    mass = { suspicion_above = 1e12, unit = "g" },
  },
  CMGUS = {
    rho = { suspicion_below = 0.5, suspicion_above = 30, typical_steel = 7.85, unit = "g/cm³" },
    e = { suspicion_below = 1e-4, suspicion_above = 100, typical_steel = 2.1, unit = "g·cm/μs²/cm²" },
    length = { suspicion_below = 1e-7, suspicion_above = 1e6, unit = "cm" },
    velocity = { suspicion_above = 1, unit = "cm/μs" },
    mass = { suspicion_above = 1e12, unit = "g" },
  },
  IPS = {
    rho = { suspicion_below = 5e-5, suspicion_above = 3e-3, typical_steel = 7.35e-4, unit = "slinch/in³" },
    e = { suspicion_below = 1450, suspicion_above = 1.45e9, typical_steel = 30.5e6, unit = "psi" },
    length = { suspicion_below = 4e-8, suspicion_above = 4e5, unit = "in" },
    velocity = { suspicion_above = 4e5, unit = "in/s" },
    mass = { suspicion_above = 5.7e6, unit = "slinch" },
  },
  MMGMS = {
    rho = { suspicion_below = 5e-4, suspicion_above = 0.03, typical_steel = 7.85e-3, unit = "g/mm³" },
    e = { suspicion_below = 10, suspicion_above = 1e7, typical_steel = 2.1e5, unit = "g·mm/ms²/mm²" },
    length = { suspicion_below = 1e-6, suspicion_above = 1e7, unit = "mm" },
    velocity = { suspicion_above = 1e4, unit = "mm/ms" },
    mass = { suspicion_above = 1e12, unit = "g" },
  },
  MMMGMS = {
    rho = { suspicion_below = 0.5, suspicion_above = 30, typical_steel = 7.85, unit = "mg/mm³" },
    e = { suspicion_below = 1e4, suspicion_above = 1e10, typical_steel = 2.1e8, unit = "mg·mm/ms²/mm²" },
    length = { suspicion_below = 1e-6, suspicion_above = 1e7, unit = "mm" },
    velocity = { suspicion_above = 1e4, unit = "mm/ms" },
    mass = { suspicion_above = 1e15, unit = "mg" },
  },
}

local unit_system_aliases = {
  ["SI"] = "SI",
  ["MMTONS"] = "MMTONS",
  ["MM/TON/S"] = "MMTONS",
  ["CMGUS"] = "CMGUS",
  ["CM/G/US"] = "CMGUS",
  ["IPS"] = "IPS",
  ["MMKGMS"] = "MMKGMS",
  ["MM/KG/MS"] = "MMKGMS",
  ["CMGS"] = "CMGS",
  ["CM/G/S"] = "CMGS",
  ["MMGMS"] = "MMGMS",
  ["MM/G/MS"] = "MMGMS",
  ["MMMGMS"] = "MMMGMS",
  ["MM/MG/MS"] = "MMMGMS",
}

local function get_unit_system(lines)
  for i, raw in ipairs(lines) do
    local kw = raw:match("^%s*(%*UNIT_SYSTEM)")
    if kw then
      for j = i + 1, #lines do
        local t = trim(lines[j] or "")
        if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" then
          local val = trim(t:match('"(.-)"') or t:match("^([^,]+)") or t)
          val = val:upper()
          return unit_system_aliases[val] or val, j
        end
      end
    end
  end
  return nil, nil
end

-- =====================================================================
-- Check functions
-- =====================================================================

local function check_control_blocks(ctx, diagnostics)
  local lines = ctx.lines
  local if_stack = {}
  local repeat_stack = {}
  local convert_stack = {}

  for i, raw in ipairs(lines) do
    local line = trim(raw):lower()
    if starts_with(line, "~if") then
      if_stack[#if_stack + 1] = i
    elseif starts_with(line, "~else_if") then
      if #if_stack == 0 then
        push_diagnostic(diagnostics, i - 1, 0, SEV.ERROR, "~else_if without matching ~if")
      end
    elseif starts_with(line, "~else") then
      if #if_stack == 0 then
        push_diagnostic(diagnostics, i - 1, 0, SEV.ERROR, "~else without matching ~if")
      end
    elseif starts_with(line, "~end_if") then
      if #if_stack == 0 then
        push_diagnostic(diagnostics, i - 1, 0, SEV.ERROR, "~end_if without matching ~if")
      else
        table.remove(if_stack)
      end
    elseif starts_with(line, "~repeat") then
      repeat_stack[#repeat_stack + 1] = i
    elseif starts_with(line, "~end_repeat") then
      if #repeat_stack == 0 then
        push_diagnostic(diagnostics, i - 1, 0, SEV.ERROR, "~end_repeat without matching ~repeat")
      else
        table.remove(repeat_stack)
      end
    elseif starts_with(line, "~convert_from_") then
      convert_stack[#convert_stack + 1] = i
      if not ctx.seen_unit_system then
        push_diagnostic(diagnostics, i - 1, 0, SEV.WARNING, "Unit conversion used before *UNIT_SYSTEM is defined")
      end
    elseif starts_with(line, "~end_convert") then
      if #convert_stack == 0 then
        push_diagnostic(diagnostics, i - 1, 0, SEV.ERROR, "~end_convert without matching ~convert_from_")
      else
        table.remove(convert_stack)
      end
    end
  end

  for _, ln in ipairs(if_stack) do
    push_diagnostic(diagnostics, ln - 1, 0, SEV.ERROR, "Unclosed ~if block")
  end
  for _, ln in ipairs(repeat_stack) do
    push_diagnostic(diagnostics, ln - 1, 0, SEV.ERROR, "Unclosed ~repeat block")
  end
  for _, ln in ipairs(convert_stack) do
    push_diagnostic(diagnostics, ln - 1, 0, SEV.ERROR, "Unclosed ~convert_from_ block")
  end
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
  if d:find("default:", 1, true) then
    return true
  end
  if d:find("default =", 1, true) then
    return true
  end
  if d:find("default value", 1, true) then
    return true
  end
  if d:find("(default)", 1, true) then
    return true
  end
  return false
end

local function extract_options_from_desc(desc)
  local d = trim(desc or "")
  if d == "" then
    return nil
  end
  d = d:lower()

  -- Range expression like "1 leq VAR leq 99" or "1 <= VAR <= 99"
  local lo, hi = d:match("(%d+)%s*leq%s*[%w_]+%s*leq%s*(%d+)")
  if not lo then
    lo, hi = d:match("(%d+)%s*<=%s*[%w_]+%s*<=%s*(%d+)")
  end
  if lo and hi then
    local opts = {}
    opts["__ge__"] = tonumber(lo)
    opts["__le__"] = tonumber(hi)
    return opts
  end

  local opts = {}

  -- Pattern 1: [options: a, b, c] or options: a, b, c (single line)
  local opts_text = d:match("%[options:%s*([^%]]*)%]") or d:match("options:%s*([^%]]+)")
  if opts_text then
    opts_text = trim(opts_text)
    -- Skip "or" style options (e.g. "time or fcn") —too vague for strict checking
    if opts_text ~= "" and not opts_text:find(" or ", 1, true) and not opts_text:find("->", 1, true) then
      for part in opts_text:gmatch("[^,;]+") do
        local v = trim(part)
        if v ~= "" then
          opts[v:upper()] = true
        end
      end
      if next(opts) then
        return opts
      end
    end
  end

  -- Pattern 2: Explanatory lists like "SI -> [m, kg, s] MMTONS or MM/TON/S -> [mm, ton, s] ..."
  -- Extract option names that appear before "->"
  if d:find("options:", 1, true) and d:find("->", 1, true) then
    local rest = d:match("options:%s*(.-)%s*$") or ""
    for segment in rest:gmatch("([%w%s/]+)%s*%-[>%-]") do
      segment = trim(segment)
      if segment ~= "" then
        for part in segment:gmatch("[^%s]+") do
          part = trim(part)
          if part ~= "" and part ~= "or" then
            opts[part:upper()] = true
          end
        end
      end
    end
  end

  -- Pattern 3: inline "0 -> ...", "1 -> ...", "A -> ..."
  for val in d:gmatch("(%d+)%s*%-[>%-]") do
    opts[val] = true
  end
  for val in d:gmatch("([a-z])%s*%-[>%-]") do
    opts[val:upper()] = true
  end

  -- Pattern 4: range options like "> 2 -> ..." or ">= 2 -> ..."
  for val in d:gmatch(">%s*(%d+)%s*%-[>%-]") do
    opts["__gt__"] = tonumber(val)
  end
  for val in d:gmatch(">=%s*(%d+)%s*%-[>%-]") do
    opts["__ge__"] = tonumber(val)
  end

  if next(opts) then
    return opts
  end
  return nil
end

-- Try to find a description for a parameter, handling slight naming
-- mismatches between signature_rows and descriptions (e.g. N_p^sid vs N_p^sbdid).
local function find_desc_for_param(desc, param_name)
  if not desc or not param_name then
    return nil
  end
  if desc[param_name] then
    return desc[param_name]
  end
  local base = param_name:match("^(.-)%^") or param_name
  for k, v in pairs(desc) do
    local other_base = k:match("^(.-)%^") or k
    if base == other_base then
      return v
    end
  end
  return nil
end

local function check_unknown_keywords(ctx, diagnostics)
  local lines = ctx.lines
  local db = ctx.db
  for i, raw in ipairs(lines) do
    local line = trim(raw)
    local keyword = line:match("^(%*[%u%d_%-]+)")
    if keyword then
      local entry = db[keyword]
      if not entry then
        -- Custom user-defined *MAT_* keywords are allowed
        if not keyword:upper():match("^%*MAT_") then
          push_diagnostic(diagnostics, i - 1, 0, SEV.WARNING, "Unknown keyword in commands.help database: " .. keyword)
        end
      end
    end
  end
end

local function check_field_counts(ctx, diagnostics)
  local lines = ctx.lines
  local db = ctx.db
  local current_keyword = nil
  local current_entry = nil
  local expected_fields = nil
  local seen_data_line = false

  for i, raw in ipairs(lines) do
    local line = trim(raw)
    local keyword = line:match("^(%*[%u%d_%-]+)")
    if keyword then
      current_keyword = keyword
      current_entry = db[keyword]
      seen_data_line = false
      expected_fields = nil
      if current_entry and current_entry.signature_rows and current_entry.signature_rows[1] then
        expected_fields = #current_entry.signature_rows[1]
      end
    elseif current_keyword and line ~= "" and line:sub(1, 1) ~= "#" and line:sub(1, 1) ~= "$" and line:sub(1, 1) ~= "~" and not line:match('^".*"$') then
      if not seen_data_line and expected_fields and expected_fields > 0 then
        seen_data_line = true
        local kw_upper = current_keyword:upper()
        -- Skip field-count checks for keyword families with highly variable / optional trailing fields
        local skip_field_count = (
          kw_upper == "*PARAMETER"
          or kw_upper == "*PARAMETER_DEFAULT"
          or kw_upper == "*FUNCTION"
          or kw_upper:match("^%*MAT_")
          or kw_upper == "*PART"
          or kw_upper == "*OUTPUT_USER"
          or kw_upper == "*CFD_WIND_TUNNEL"
        )
        if not skip_field_count then
          local got = count_csv_fields(line)
          local effective_expected = expected_fields

          -- Detect omitted optional ID row:
          -- If schema row 1 is a single field (e.g. coid/bcid) and row 2 exists,
          -- and the first data value is non-numeric, the user likely omitted the ID row.
          if current_entry and current_entry.signature_rows then
            local sig1 = current_entry.signature_rows[1]
            local sig2 = current_entry.signature_rows[2]
            if sig1 and #sig1 == 1 and sig2 and #sig2 > 1 then
              local first_val = trim(line:match("^([^,]+)") or "")
              if not (
                first_val:match("^[+-]?%d+$")
                or first_val:match("^[+-]?%d+%.0+$")
                or first_val:match("^%%[%w_]+$")
                or first_val:match("^%[%%[%w_]+%]$")
              ) then
                local first_param = sig1[1] or ""
                local is_id_like = first_param:match("^%d+$") or first_param:match("^[%a_]*[iI][dD]$")
                if is_id_like then
                  effective_expected = #sig2
                end
              end
            end
          end

          if got > effective_expected then
            push_diagnostic(
              diagnostics,
              i - 1,
              0,
              SEV.ERROR,
              "Field count exceeds signature row, expected at most " .. effective_expected .. ", got " .. got
            )
          end
        end
      end
    end
  end
end

local function check_param_refs(ctx, diagnostics)
  local idx = ctx.idx
  local cross = ctx.cross_file_params
  for name, refs in pairs(idx.params.refs or {}) do
    local has_def = cross and cross.defs[name] and #cross.defs[name] > 0
    if not has_def then
      local first = refs[1]
      if first then
        push_diagnostic(
          diagnostics,
          (first.row or 1) - 1,
          first.col or 0,
          SEV.ERROR,
          "Parameter %" .. name .. " is referenced but not defined"
        )
      end
    end
  end
end

local function check_unused_params(ctx, diagnostics)
  local idx = ctx.idx
  local cross = ctx.cross_file_params
  local lines = ctx.lines

  -- Pre-compute *OBJECT block ranges
  local object_ranges = {}
  local i = 1
  while i <= #lines do
    local kw = trim(lines[i] or ""):match("^(%*[%u%d_%-]+)")
    if kw and kw:upper() == "*OBJECT" then
      local start_i = i
      local end_i = #lines
      for j = i + 1, #lines do
        if trim(lines[j] or ""):match("^(%*[%u%d_%-]+)") then
          end_i = j - 1
          break
        end
      end
      object_ranges[#object_ranges + 1] = { start = start_i, finish = end_i }
      i = end_i
    end
    i = i + 1
  end

  local function inside_object(row)
    for _, r in ipairs(object_ranges) do
      if row > r.start and row <= r.finish then
        return true
      end
    end
    return false
  end

  for name, defs in pairs(idx.params.defs or {}) do
    local used = false
    if cross and cross.refs[name] then
      for _, ref in ipairs(cross.refs[name]) do
        local is_self_ref = false
        for _, def in ipairs(defs) do
          if ref.row == def.row then
            is_self_ref = true
            break
          end
        end
        if not is_self_ref then
          used = true
          break
        end
      end
    end
    if not used then
      local first = defs[1]
      if first and not inside_object(first.row) then
        push_diagnostic(
          diagnostics,
          (first.row or 1) - 1,
          first.col or 0,
          SEV.WARNING,
          "Parameter %" .. name .. " is defined but never used",
          first.end_col
        )
      end
    end
  end
end

local function check_duplicate_ids(ctx, diagnostics)
  local idx = ctx.idx
  local all_defs = idx.object_defs_all or {}

  -- Map keyword to family namespace for duplicate checking.
  -- IDs must be unique within a family, but may repeat across families.
  local function keyword_to_family(kw)
    local k = (kw or ""):upper()
    if k:match("^%*MAT_") then return "material" end
    if k:match("^%*SET_") then return "set" end
    if k:match("^%*GEOMETRY") then return "geometry" end
    if k == "*PART" or k:match("^%*PART_") then return "part" end
    if k == "*CURVE" or k == "*FUNCTION" then return "curve" end
    if k == "*NODE" then return "node" end
    if k:match("^%*ELEMENT") then return "element" end
    if k:match("^%*COORDINATE_SYSTEM") then return "coordinate_system" end
    if k == "*BC_MOTION" then return "bc_motion" end
    if k:match("^%*LOAD_") then return k:sub(2) end
    if k:match("^%*CFD_") then return k:sub(2) end
    if k:match("^%*CONTACT_") then return "contact" end
    if k:match("^%*CONNECTOR_") then return "connector" end
    if k:match("^%*COMPONENT_") then return "component" end
    if k == "*OUTPUT_USER" then return "command" end
    if k:match("^%*PARTICLE_") then return k:sub(2) end
    if k == "*PROP_DAMAGE_CL" or k == "*PROP_DAMAGE_JC" then return "prop_damage" end
    if k == "*PROP_THERMAL" then return "prop_thermal" end
    if k:match("^%*EOS") then return "eos" end
    if k == "*TABLE" then return "table" end
    if k == "*PATH" then return "path" end
    return nil
  end

  local family_ids = {}
  local seen_family_defs = {}

  for obj_type, ids in pairs(all_defs) do
    for idv, defs in pairs(ids) do
      for _, def in ipairs(defs) do
        local family = keyword_to_family(def.keyword)
        if family then
          family_ids[family] = family_ids[family] or {}
          family_ids[family][idv] = family_ids[family][idv] or {}
          -- Deduplicate: the same physical location should only count once,
          -- even if it was stored under multiple obj_types (e.g. hard-coded
          -- dp + schema-driven command for the same *PARTICLE_HE sbdid).
          local dup_key = string.format("%d:%d:%s:%s", def.row, def.col or 0, def.keyword or "", idv)
          if not seen_family_defs[dup_key] then
            seen_family_defs[dup_key] = true
            table.insert(family_ids[family][idv], def)
          end
        end
      end
    end
  end

  for family, ids in pairs(family_ids) do
    for idv, defs in pairs(ids) do
      if #defs > 1 then
        table.sort(defs, function(a, b) return a.row < b.row end)
        for i, def in ipairs(defs) do
          local other = defs[i == 1 and 2 or 1]
          push_diagnostic(
            diagnostics,
            (def.row or 1) - 1,
            def.col or 0,
            SEV.ERROR,
            "Duplicate " .. family .. " ID " .. idv
              .. " (also defined in " .. other.keyword .. " L" .. other.row .. ")"
          )
        end
      end
    end
  end
end

local function check_missing_includes(ctx, diagnostics)
  local lines = ctx.lines
  local buf_file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ctx.bufnr), ":p")
  local dir = vim.fn.fnamemodify(buf_file, ":h")
  local in_include = false

  for i, raw in ipairs(lines) do
    local kw = raw:match("^%s*(%*[%u%d_%-]+)")
    if kw then
      in_include = (trim(kw):upper() == "*INCLUDE")
    elseif in_include then
      local t = trim(raw)
      if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" then
        local path = t:match('"(.-)"') or trim(t:match("^([^,]+)") or "")
        if path and path ~= "" then
          if not path:match("^[A-Za-z]:") and not path:match("^[/\\]") then
            path = dir .. "/" .. path
          end
          local abs = vim.fn.fnamemodify(path, ":p")
          if vim.fn.filereadable(abs) == 0 then
            push_diagnostic(diagnostics, i - 1, 0, SEV.ERROR, "*INCLUDE file not found: " .. abs)
          end
        end
        in_include = false
      end
    end
  end
end

local function check_empty_blocks(ctx, diagnostics)
  local lines = ctx.lines
  local db = ctx.db
  -- Keywords that are allowed to have no data rows
  local empty_ok = {
    ["*END"] = true,
    ["*TITLE"] = true,
  }

  local i = 1
  while i <= #lines do
    local kw = trim(lines[i] or ""):match("^(%*[%u%d_%-]+)")
    if kw then
      local start_i = i
      local end_i = #lines
      for j = i + 1, #lines do
        if trim(lines[j] or ""):match("^(%*[%u%d_%-]+)") then
          end_i = j - 1
          break
        end
      end
      -- Count data rows (skip titles, comments, directives)
      local data_count = 0
      for j = start_i + 1, end_i do
        local t = trim(lines[j] or "")
        local is_title = t:match('^".*"$') ~= nil
        if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" and t:sub(1, 1) ~= "~" and not is_title then
          data_count = data_count + 1
        end
      end
      if data_count == 0 and not empty_ok[kw:upper()] then
        local entry = db[kw]
        -- Only warn if the keyword is known to expect data
        if entry and entry.signature_rows and #entry.signature_rows > 0 then
          push_diagnostic(diagnostics, start_i - 1, 0, SEV.ERROR, "Empty keyword block: " .. kw)
        end
      end
      i = end_i
    end
    i = i + 1
  end
end

local function check_object_refs_valid(ctx, diagnostics)
  local idx = ctx.idx
  local cross = ctx.cross_file_objects
  for obj_type, refs_by_id in pairs(idx.object_refs or {}) do
    for idv, refs in pairs(refs_by_id) do
      -- Priority: check local file first, then cross-file (includes + open buffers)
      local local_def = idx.objects[obj_type] and idx.objects[obj_type][idv]
      local cross_def = cross and cross.defs and cross.defs[obj_type] and cross.defs[obj_type][idv]
      if not local_def and not cross_def then
        for _, ref in ipairs(refs) do
          push_diagnostic(
            diagnostics,
            (ref.row or 1) - 1,
            ref.col or 0,
            SEV.ERROR,
            "Reference to undefined " .. obj_type .. " ID " .. idv
          )
        end
      end
    end
  end
end

local function check_unused_curves(ctx, diagnostics)
  local idx = ctx.idx
  local cross = ctx.cross_file_objects
  local curve_defs = idx.object_defs.curve
  if not curve_defs then
    return
  end

  -- Collect all curve references across the file set
  local all_refs = {}
  for idv, _ in pairs(idx.object_refs.curve or {}) do
    all_refs[idv] = true
  end
  if cross and cross.refs and cross.refs.curve then
    for idv, _ in pairs(cross.refs.curve) do
      all_refs[idv] = true
    end
  end

  for idv, def_info in pairs(curve_defs) do
    if not all_refs[idv] then
      push_diagnostic(
        diagnostics,
        (def_info.row or 1) - 1,
        def_info.col or 0,
        SEV.WARNING,
        "Curve/Function ID " .. idv .. " is defined but never referenced"
      )
    end
  end
end

local function check_required_fields(ctx, diagnostics)
  local lines = ctx.lines
  local db = ctx.db

  local i = 1
  while i <= #lines do
    local kw = trim(lines[i] or ""):match("^(%*[%u%d_%-]+)")
    if kw then
      local kw_upper = kw:upper()
      local entry = db[kw]
      if entry and entry.signature_rows and #entry.signature_rows > 0 then
        local start_i = i
        local end_i = #lines
        for j = i + 1, #lines do
          if trim(lines[j] or ""):match("^(%*[%u%d_%-]+)") then
            end_i = j - 1
            break
          end
        end

        -- Collect data rows (skip titles, comments, directives)
        local data_rows = {}
        for j = start_i + 1, end_i do
          local t = trim(lines[j] or "")
          local is_title = t:match('^".*"$') ~= nil
          -- Empty lines inside a keyword block are legal data rows (all defaults)
          if t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" and t:sub(1, 1) ~= "~" and not is_title then
            data_rows[#data_rows + 1] = j
          end
        end

        local kw_upper = kw:upper()

        -- =====================================================================
        -- Special per-keyword-family handling
        -- =====================================================================

        if kw_upper == "*END" then
          -- *END terminates the input; solver ignores all trailing content.
          -- Do not run required-field checks on lines after *END.

        elseif kw_upper == "*PARAMETER" or kw_upper == "*PARAMETER_DEFAULT" then
          -- Only %param = expression is required; description/rid/quantity are optional
          -- Parameter name may or may not have a leading %
          if #data_rows > 0 then
            local line = lines[data_rows[1]]
            if not line:match("^%s*%%?[%w_]+%s*=%s*.") then
              push_diagnostic(diagnostics, data_rows[1] - 1, 0, SEV.ERROR, "Missing parameter definition in " .. kw)
            end
          end

        elseif kw_upper == "*FUNCTION" then
          -- Only fid on first row and expression on second row are required
          if #data_rows == 0 then
            push_diagnostic(diagnostics, start_i - 1, 0, SEV.WARNING, "Empty keyword block: " .. kw)
          else
            local fields = split_csv_keep_empty(lines[data_rows[1]])
            local fid = trim(fields[1] or "")
            if fid == "" or fid == "-" then
              push_diagnostic(diagnostics, data_rows[1] - 1, 0, SEV.ERROR, "Missing required field 'fid' in " .. kw)
            end
            if #data_rows < 2 then
              push_diagnostic(diagnostics, start_i - 1, 0, SEV.ERROR, "Missing expression row in " .. kw)
            else
              local expr = trim(lines[data_rows[2]] or "")
              if expr == "" then
                push_diagnostic(diagnostics, data_rows[2] - 1, 0, SEV.ERROR, "Missing expression in " .. kw)
              end
            end
          end

        elseif kw_upper:match("^%*MAT_") then
          -- Material keywords: only mid/id is strictly required, be very lenient
          if #data_rows > 0 then
            local sig = entry.signature_rows[1] or {}
            local fields = split_csv_keep_empty(lines[data_rows[1]])
            for fi, param_name in ipairs(sig) do
              local p = normalize_param_name(param_name)
              if p == "mid" or p == "id" then
                local val = trim(fields[fi] or "")
                if val == "" or val == "-" then
                  push_diagnostic(
                    diagnostics,
                    data_rows[1] - 1,
                    0,
                    SEV.ERROR,
                    "Missing required field '" .. param_name .. "' in " .. kw
                  )
                end
              end
            end
          end

        elseif kw_upper == "*PART" then
          -- PART: pid is strictly required; mid is required unless this part
          -- is referenced by a *GEOMETRY_PART (geometry-only part needs no material).
          if #data_rows > 0 then
            local sig = entry.signature_rows[1] or {}
            local fields = split_csv_keep_empty(lines[data_rows[1]])
            local part_pid = nil
            for fi, param_name in ipairs(sig) do
              local p = normalize_param_name(param_name)
              if p == "pid" then
                part_pid = trim(fields[fi] or "")
              end
            end
            for fi, param_name in ipairs(sig) do
              local p = normalize_param_name(param_name)
              local val = trim(fields[fi] or "")
              if val == "" or val == "-" then
                if p == "pid" then
                  push_diagnostic(
                    diagnostics,
                    data_rows[1] - 1,
                    0,
                    SEV.ERROR,
                    "Missing required field '" .. param_name .. "' in " .. kw
                  )
                elseif p == "mid" then
                  if not ctx.geometry_part_pids[part_pid] then
                    push_diagnostic(
                      diagnostics,
                      data_rows[1] - 1,
                      0,
                      SEV.ERROR,
                      "Missing required field '" .. param_name .. "' in " .. kw
                    )
                  end
                end
              end
            end
          end

        elseif kw_upper == "*OUTPUT" then
          -- OUTPUT: first three fields get defaults from *TIME t_term when present.
          -- If *TIME t_term exists, all three are optional; otherwise only first two
          -- (Δt_imp, Δt_ascii) are required.
          if #data_rows > 0 then
            local sig = entry.signature_rows[1] or {}
            local fields = split_csv_keep_empty(lines[data_rows[1]])
            local required_count = ctx.has_time_with_t_term and 0 or 2
            for fi, param_name in ipairs(sig) do
              if fi <= required_count then
                local val = trim(fields[fi] or "")
                if val == "" or val == "-" then
                  push_diagnostic(
                    diagnostics,
                    data_rows[1] - 1,
                    0,
                    SEV.ERROR,
                    "Missing required field '" .. param_name .. "' in " .. kw
                  )
                end
              end
            end
          end

        elseif kw_upper == "*PARTICLE_DOMAIN" then
          -- N_p is optional only if *GENERATE_PARTICLE_DISTRIBUTION exists in the file
          if #data_rows > 0 then
            local sig = entry.signature_rows[1] or {}
            local desc = entry.descriptions or {}
            local fields = split_csv_keep_empty(lines[data_rows[1]])
            local has_generate_particle = false
            for _, k in ipairs(ctx.idx.keywords or {}) do
              if k.keyword:upper() == "*GENERATE_PARTICLE_DISTRIBUTION" then
                has_generate_particle = true
                break
              end
            end
            for fi, param_name in ipairs(sig) do
              local p = normalize_param_name(param_name)
              if p == "n_p" then
                local val = trim(fields[fi] or "")
                if (val == "" or val == "-") and not has_generate_particle then
                  push_diagnostic(
                    diagnostics,
                    data_rows[1] - 1,
                    0,
                    SEV.ERROR,
                    "Missing required field '" .. param_name .. "' in " .. kw
                      .. " (*GENERATE_PARTICLE_DISTRIBUTION not found)"
                  )
                end
              else
                local param_desc = find_desc_for_param(desc, param_name)
                local is_optional = description_marks_optional(param_desc)
                -- If entype is empty or 0, enid is optional (no structure interaction)
                if p == "enid" then
                  local entype_val = trim(fields[1] or "")
                  if entype_val == "" or entype_val == "0" then
                    is_optional = true
                  end
                end
                local has_options = extract_options_from_desc(param_desc) ~= nil
                -- If previous field is ALL, current enid/eid field is optional
                local prev_val = fi > 1 and trim(fields[fi - 1] or "") or ""
                local is_all_entity_id = (p:match("^enid") or p:match("^eid")) and prev_val:upper() == "ALL"
                if not is_optional and not has_options and not is_all_entity_id then
                  if fi <= #fields then
                    local val = trim(fields[fi] or "")
                    if val == "" or val == "-" then
                      push_diagnostic(
                        diagnostics,
                        data_rows[1] - 1,
                        0,
                        SEV.ERROR,
                        "Missing required field '" .. param_name .. "' in " .. kw
                      )
                    end
                  end
                end
              end
            end
          end

        elseif kw_upper == "*OUTPUT_SENSOR" then
          if #data_rows > 0 then
            local sig = entry.signature_rows[1] or {}
            local desc = entry.descriptions or {}
            -- Check required fields for ALL data rows (each row is an independent sensor definition)
            for _, dr in ipairs(data_rows) do
              local fields = split_csv_keep_empty(lines[dr])
              for fi, param_name in ipairs(sig) do
                local p = normalize_param_name(param_name)
                if p ~= "" and p ~= "." and p ~= "..." and p ~= "-" then
                  local param_desc = find_desc_for_param(desc, param_name)
                  local is_optional = description_marks_optional(param_desc)
                  local has_options = extract_options_from_desc(param_desc) ~= nil
                  local prev_val = fi > 1 and trim(fields[fi - 1] or "") or ""
                  local is_all_entity_id = (p:match("^enid") or p:match("^eid")) and prev_val:upper() == "ALL"
                  -- R is required only when pid == "DP"
                  if p == "r" then
                    local pid_val = trim(fields[2] or ""):upper()
                    is_optional = (pid_val ~= "DP")
                  end
                  if not is_optional and not has_options and not is_all_entity_id then
                    local val = trim(fields[fi] or "")
                    if val == "" or val == "-" then
                      push_diagnostic(
                        diagnostics,
                        dr - 1,
                        0,
                        SEV.ERROR,
                        "Missing required field '" .. param_name .. "' in " .. kw
                      )
                    end
                  end
                end
              end
            end
          end

          -- When pid == "DP", R (field 6) must be present and positive
          for _, dr in ipairs(data_rows) do
            local fields = split_csv_keep_empty(lines[dr])
            local pid = trim(fields[2] or ""):upper()
            if pid == "DP" then
              local r_val = trim(fields[6] or "")
              if r_val == "" or r_val == "-" then
                push_diagnostic(
                  diagnostics,
                  dr - 1,
                  0,
                  SEV.ERROR,
                  "Missing required field 'R' (sensor sampling radius) in *OUTPUT_SENSOR when pid=DP"
                )
              else
                local r_num = to_number(r_val)
                if r_num and r_num <= 0 then
                  push_diagnostic(
                    diagnostics,
                    dr - 1,
                    field_col_from_idx(lines[dr], 6),
                    SEV.ERROR,
                    "Field 'R' (sensor sampling radius) must be positive when pid=DP in *OUTPUT_SENSOR"
                  )
                end
              end
            end
          end

        elseif kw_upper == "*CFD_HE" then
          if #data_rows >= 2 then
            local fields2 = split_csv_keep_empty(lines[data_rows[2]])
            local raw_type = trim(fields2[1] or "")
            local type_val = raw_type:upper()
            local is_preset = false
            for _, p in ipairs({
              "ANFO", "C4", "COMPA", "COMPB", "HMX",
              "LX-10-1", "LX-14-0", "M46", "MCX-6100",
              "NSP-711", "OCTOL", "PBXN-110", "PBXN-9010",
              "PETN", "TETRYL", "TNT",
            }) do
              if p == type_val then
                is_preset = true
                break
              end
            end
            local is_user = type_val == "USER"
            -- Accept plain integer, param reference (%id), or bracket expression ([id])
            local is_mid = raw_type:match("^[+-]?%d+$") ~= nil
              or raw_type:match("^%%[%w_]+$") ~= nil
              or raw_type:match("^%[%%[%w_]+%]$") ~= nil
            if not is_preset and not is_user and not is_mid then
              push_diagnostic(
                diagnostics,
                data_rows[2] - 1,
                0,
                SEV.ERROR,
                "Invalid value '" .. raw_type .. "' for field 'type' in " .. kw
                  .. ". Expected: preset name, user, or *MAT_EXPLOSIVE_JWL id"
              )
            elseif is_mid and raw_type:match("^[+-]?%d+$") and not ctx.mat_explosive_jwl_ids[raw_type] then
              push_diagnostic(
                diagnostics,
                data_rows[2] - 1,
                0,
                SEV.ERROR,
                "Material id '" .. raw_type .. "' in " .. kw
                  .. " is not a defined *MAT_EXPLOSIVE_JWL"
              )
            end
            -- Row 2: check gid and follow with generic logic (skip type)
            local sig2 = entry.signature_rows[2] or {}
            local desc = entry.descriptions or {}
            for fi, param_name in ipairs(sig2) do
              if fi > 1 then
                local p = normalize_param_name(param_name)
                if p ~= "" and p ~= "." and p ~= "..." and p ~= "-" then
                  local param_desc = find_desc_for_param(desc, param_name)
                  local is_optional = description_marks_optional(param_desc)
                  local has_options = extract_options_from_desc(param_desc) ~= nil
                  -- follow defaults to 0 when omitted
                  if p == "follow" then
                    is_optional = true
                  end
                  if not is_optional and not has_options then
                    local val = trim(fields2[fi] or "")
                    if val == "" or val == "-" then
                      push_diagnostic(
                        diagnostics,
                        data_rows[2] - 1,
                        0,
                        SEV.ERROR,
                        "Missing required field '" .. param_name .. "' in " .. kw
                      )
                    end
                  end
                end
              end
            end
            -- Row 3 required only when type == user
            if is_user then
              if #data_rows < 3 then
                push_diagnostic(
                  diagnostics,
                  data_rows[2] - 1,
                  0,
                  SEV.ERROR,
                  "*CFD_HE type=user requires a user-defined explosive data row (row 3)"
                )
              else
                local sig3 = entry.signature_rows[3] or {}
                local fields3 = split_csv_keep_empty(lines[data_rows[3]])
                for fi3, param_name3 in ipairs(sig3) do
                  local p3 = normalize_param_name(param_name3)
                  if p3 ~= "" and p3 ~= "." and p3 ~= "..." and p3 ~= "-" then
                    local val3 = trim(fields3[fi3] or "")
                    if val3 == "" or val3 == "-" then
                      push_diagnostic(
                        diagnostics,
                        data_rows[3] - 1,
                        0,
                        SEV.ERROR,
                        "Missing required field '" .. param_name3 .. "' in " .. kw
                      )
                    end
                  end
                end
              end
            end
          end

        elseif kw_upper == "*GEOMETRY_COMPOSITE" then
          -- Row 2+ contains sub-geometry IDs with optional negative sign (boolean subtraction)
          if #data_rows >= 2 then
            local fields2 = split_csv_keep_empty(lines[data_rows[2]])
            local has_any = false
            for fi, val in ipairs(fields2) do
              local t = trim(val)
              if t ~= "" and t ~= "-" then
                has_any = true
              end
            end
            if not has_any then
              push_diagnostic(
                diagnostics,
                data_rows[2] - 1,
                0,
                SEV.ERROR,
                "Missing sub-geometry IDs in " .. kw
              )
            end
          end

        elseif kw_upper == "*CFD_WIND_TUNNEL" then
          -- Only the first field (fid_v) is required; trailing fields are optional
          if #data_rows > 0 then
            local fields = split_csv_keep_empty(lines[data_rows[1]])
            local val = trim(fields[1] or "")
            if val == "" or val == "-" then
              push_diagnostic(
                diagnostics,
                data_rows[1] - 1,
                0,
                SEV.ERROR,
                "Missing required field 'fid_v' in " .. kw
              )
            end
          end

        elseif kw_upper == "*INITIAL_STRESS_FUNCTION" then
          -- Row 1: entype, enid are required; fid_xx~fid_zx are optional (default: 0)
          if #data_rows > 0 then
            local sig = entry.signature_rows[1] or {}
            local desc = entry.descriptions or {}
            local fields = split_csv_keep_empty(lines[data_rows[1]])
            for fi, param_name in ipairs(sig) do
              local p = normalize_param_name(param_name)
              if p ~= "" and p ~= "." and p ~= "..." and p ~= "-" then
                local is_optional = (fi >= 3)
                if not is_optional then
                  local param_desc = find_desc_for_param(desc, param_name)
                  is_optional = description_marks_optional(param_desc)
                end
                local has_options = extract_options_from_desc(find_desc_for_param(desc, param_name)) ~= nil
                if not is_optional and not has_options then
                  local val = trim(fields[fi] or "")
                  if val == "" or val == "-" then
                    push_diagnostic(
                      diagnostics,
                      data_rows[1] - 1,
                      0,
                      SEV.ERROR,
                      "Missing required field '" .. param_name .. "' in " .. kw
                    )
                  end
                end
              end
            end
          end

        elseif kw_upper == "*TRANSFORM_MESH_CARTESIAN" or kw_upper == "*TRANSFORM_MESH_CYLINDRICAL" then
          -- coid, entype, enid, csysid are required; fid_1~fid_4 are optional (default: 0)
          if #data_rows > 0 then
            local sig = entry.signature_rows[1] or {}
            local desc = entry.descriptions or {}
            local fields = split_csv_keep_empty(lines[data_rows[1]])
            for fi, param_name in ipairs(sig) do
              local p = normalize_param_name(param_name)
              if p ~= "" and p ~= "." and p ~= "..." and p ~= "-" then
                local is_optional = p:match("^fid_%d+$")
                if not is_optional then
                  local param_desc = find_desc_for_param(desc, param_name)
                  is_optional = description_marks_optional(param_desc)
                end
                local has_options = extract_options_from_desc(find_desc_for_param(desc, param_name)) ~= nil
                if not is_optional and not has_options then
                  local val = trim(fields[fi] or "")
                  if val == "" or val == "-" then
                    push_diagnostic(
                      diagnostics,
                      data_rows[1] - 1,
                      0,
                      SEV.ERROR,
                      "Missing required field '" .. param_name .. "' in " .. kw
                    )
                  end
                end
              end
            end
          end

        else
          -- Generic check for all other keywords
          if #data_rows > 0 then
            local sig = entry.signature_rows[1] or {}
            local desc = entry.descriptions or {}
            local fields = split_csv_keep_empty(lines[data_rows[1]])
            for fi, param_name in ipairs(sig) do
              local p = normalize_param_name(param_name)
              -- Skip reserved/placeholder fields (-, ., ...)
              if p ~= "" and p ~= "." and p ~= "..." and p ~= "-" then
                local param_desc = find_desc_for_param(desc, param_name)
                local is_optional = description_marks_optional(param_desc)
                -- Fields with explicit options lists default to first option when empty,
                -- so they are not treated as strictly required.
                local has_options = extract_options_from_desc(param_desc) ~= nil
                -- If previous field is ALL, current enid/eid field is optional
                local prev_val = fi > 1 and trim(fields[fi - 1] or "") or ""
                local is_all_entity_id = (p:match("^enid") or p:match("^eid")) and prev_val:upper() == "ALL"
                if not is_optional and not has_options and not is_all_entity_id then
                  local val = trim(fields[fi] or "")
                  if val == "" or val == "-" then
                    push_diagnostic(
                      diagnostics,
                      data_rows[1] - 1,
                      0,
                      SEV.ERROR,
                      "Missing required field '" .. param_name .. "' in " .. kw
                    )
                  end
                end
              end
            end
          end
        end
        i = end_i
      end
    end
    i = i + 1
  end
end

local function field_col_from_idx(line, target_idx)
  local fidx = 1
  local seg_start = 1
  local i = 1
  while i <= #line do
    local ch = line:sub(i, i)
    if ch == "," then
      if fidx == target_idx then
        local s = seg_start
        while s < i and line:sub(s, s):match("%s") do
          s = s + 1
        end
        return s - 1
      end
      fidx = fidx + 1
      seg_start = i + 1
    end
    i = i + 1
  end
  if fidx == target_idx then
    local s = seg_start
    while s <= #line and line:sub(s, s):match("%s") do
      s = s + 1
    end
    return s - 1
  end
  return 0
end

local function check_physics_sanity(ctx, diagnostics)
  local unit_system = ctx.unit_system
  if not unit_system then
    return
  end

  local ranges = physics_ranges[unit_system]
  if not ranges then
    return
  end

  local lines = ctx.lines
  local db = ctx.db
  local idx = ctx.idx

  local function check_numeric_field(val, field_name, row, col)
    local num = to_number(val)
    if not num then
      -- Try resolving from parameter
      local p = trim(val)
      if p:match("^%%[%w_]+$") or p:match("^%[%%[%w_]+%]$") then
        num = resolve_param_value(p, idx)
      end
    end
    if not num then
      return
    end

    local fname = field_name:lower()
    -- Density (ρ is the Greek letter rho used in commands.help)
    if fname == "rho" or fname == "density" or fname == "ρ" then
      local r = ranges.rho
      if r then
        if num < r.suspicion_below then
          push_diagnostic(
            diagnostics,
            row - 1,
            col,
            SEV.SUSPICION,
            string.format(
              "[Suspicion] Density %.4g is far below common solid lower limit (%g %s), steel density in %s is about %g",
              num,
              r.suspicion_below,
              r.unit,
              unit_system,
              r.typical_steel
            )
          )
        elseif num > r.suspicion_above then
          push_diagnostic(
            diagnostics,
            row - 1,
            col,
            SEV.SUSPICION,
            string.format(
              "[Suspicion] Density %.4g is far above common solid upper limit (%g %s), please verify unit system",
              num,
              r.suspicion_above,
              r.unit
            )
          )
        end
      end
    end

    -- Young's modulus
    if fname == "e" or fname == "young" or fname == "youngs" then
      local r = ranges.e
      if r then
        if num < r.suspicion_below then
          push_diagnostic(
            diagnostics,
            row - 1,
            col,
            SEV.SUSPICION,
            string.format(
              "[Suspicion] Young's modulus %.4g is too low (steel in %s is about %.3g %s), possible missing unit conversion",
              num,
              unit_system,
              r.typical_steel,
              r.unit
            )
          )
        elseif num > r.suspicion_above then
          push_diagnostic(
            diagnostics,
            row - 1,
            col,
            SEV.SUSPICION,
            string.format(
              "[Suspicion] Young's modulus %.4g is too high (upper limit ~%.3g %s), please verify unit system",
              num,
              r.suspicion_above,
              r.unit
            )
          )
        end
      end
    end

    -- Length / coordinate fields (x, y, z and x_*, y_*, z_*)
    if fname:match("^[xyz]_[%w_]*$") or fname == "x" or fname == "y" or fname == "z" then
      local r = ranges.length
      if r then
        if math.abs(num) > r.suspicion_above then
          push_diagnostic(
            diagnostics,
            row - 1,
            col,
            SEV.SUSPICION,
            string.format(
              "[Suspicion] Size/coordinate %.4g exceeds %.3g %s, please verify model scale",
              num,
              r.suspicion_above,
              r.unit
            )
          )
        elseif math.abs(num) > 0 and math.abs(num) < r.suspicion_below then
          push_diagnostic(
            diagnostics,
            row - 1,
            col,
            SEV.SUSPICION,
            string.format(
              "[Suspicion] Size/coordinate %.4g is smaller than %.3g %s, please verify model scale",
              num,
              r.suspicion_below,
              r.unit
            )
          )
        end
      end
    end

    -- Velocity fields
    if fname:match("^v[xyz]?$") or fname:match("^velo") or fname:match("^velocity") then
      local r = ranges.velocity
      if r and math.abs(num) > r.suspicion_above then
        push_diagnostic(
          diagnostics,
          row - 1,
          col,
          SEV.SUSPICION,
          string.format(
            "[Suspicion] Velocity %.4g exceeds %.3g %s, approaching orbital velocity, please verify",
            num,
            r.suspicion_above,
            r.unit
          )
        )
      end
    end

    -- Mass fields
    if fname == "m" or fname == "mass" then
      local r = ranges.mass
      if r and math.abs(num) > r.suspicion_above then
        push_diagnostic(
          diagnostics,
          row - 1,
          col,
          SEV.SUSPICION,
          string.format(
            "[Suspicion] Mass %.4g exceeds %.3g %s, please verify unit",
            num,
            r.suspicion_above,
            r.unit
          )
        )
      end
    end
  end

  -- Scan all keyword blocks
  local i = 1
  while i <= #lines do
    local kw = trim(lines[i] or ""):match("^(%*[%u%d_%-]+)")
    if kw then
      local kw_upper = kw:upper()
      local start_i = i
      local end_i = #lines
      for j = i + 1, #lines do
        if trim(lines[j] or ""):match("^(%*[%u%d_%-]+)") then
          end_i = j - 1
          break
        end
      end

      local entry = db[kw]

      -- *MAT_* keywords: check schema-driven fields
      if kw_upper:match("^%*MAT_") and entry and entry.signature_rows then
        local id_row_omitted = false
        local data_row_idx = 0
        for j = start_i + 1, end_i do
          local t = trim(lines[j] or "")
          if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" and t:sub(1, 1) ~= "~" then
            data_row_idx = data_row_idx + 1

            -- Detect omitted optional ID row
            if data_row_idx == 1 then
              local sig1 = entry.signature_rows[1]
              if sig1 and #sig1 == 1 and #entry.signature_rows >= 2 then
                local first_val = trim(t:match("^([^,]+)") or "")
                if not (
                  first_val:match("^[+-]?%d+$")
                  or first_val:match("^[+-]?%d+%.0+$")
                  or first_val:match("^%%[%w_]+$")
                  or first_val:match("^%[%%[%w_]+%]$")
                ) then
                  local first_param = sig1[1] or ""
                  local is_id_like = first_param:match("^%d+$") or first_param:match("^[%a_]*[iI][dD]$")
                  if is_id_like then
                    id_row_omitted = true
                  end
                end
              end
            end

            local sig_idx = id_row_omitted and (data_row_idx + 1) or data_row_idx
            local sig = entry.signature_rows[sig_idx] or entry.signature_rows[#entry.signature_rows]
            if sig and type(sig) == "table" then
              local fields = split_csv_keep_empty(lines[j])
              for fi, param_name in ipairs(sig) do
                local val = fields[fi] or ""
                check_numeric_field(val, param_name, j, field_col_from_idx(lines[j], fi))
              end
            end
          end
        end
      end

      -- *MAT_OBJECT: tail_repeat rows are (property_name, value)
      if kw_upper == "*MAT_OBJECT" then
        local data_row_idx = 0
        for j = start_i + 1, end_i do
          local t = trim(lines[j] or "")
          if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" and t:sub(1, 1) ~= "~" then
            data_row_idx = data_row_idx + 1
            local fields = split_csv_keep_empty(lines[j])
            if data_row_idx == 1 then
              -- Header row: material ID at field 2, skip physics
            else
              -- Property row: field 1 = name, field 2 = value
              if #fields >= 2 then
                local prop_name = trim(fields[1])
                local val = fields[2]
                check_numeric_field(val, prop_name, j, field_col_from_idx(lines[j], 2))
              end
            end
          end
        end
      end

      -- General keywords: check coordinate/velocity/mass fields on all data rows
      if entry and entry.signature_rows then
        local id_row_omitted = false
        local data_row_idx = 0
        for j = start_i + 1, end_i do
          local t = trim(lines[j] or "")
          if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" and t:sub(1, 1) ~= "~" then
            data_row_idx = data_row_idx + 1

            -- Detect omitted optional ID row
            if data_row_idx == 1 then
              local sig1 = entry.signature_rows[1]
              if sig1 and #sig1 == 1 and #entry.signature_rows >= 2 then
                local first_val = trim(t:match("^([^,]+)") or "")
                if not (
                  first_val:match("^[+-]?%d+$")
                  or first_val:match("^[+-]?%d+%.0+$")
                  or first_val:match("^%%[%w_]+$")
                  or first_val:match("^%[%%[%w_]+%]$")
                ) then
                  local first_param = sig1[1] or ""
                  local is_id_like = first_param:match("^%d+$") or first_param:match("^[%a_]*[iI][dD]$")
                  if is_id_like then
                    id_row_omitted = true
                  end
                end
              end
            end

            local sig_idx = id_row_omitted and (data_row_idx + 1) or data_row_idx
            local sig = entry.signature_rows[sig_idx] or entry.signature_rows[#entry.signature_rows]
            if sig and type(sig) == "table" then
              local fields = split_csv_keep_empty(lines[j])
              for fi, param_name in ipairs(sig) do
                local val = fields[fi] or ""
                local pn = normalize_param_name(param_name)
                -- Only run physics checks on coordinate/velocity/mass fields for non-material keywords
                -- Skip *CURVE/*TABLE as well: their x/y are data points (e.g. stress vs strain),
                -- not spatial coordinates.
                if not kw_upper:match("^%*MAT_") and not (kw_upper == "*MAT_OBJECT")
                   and kw_upper ~= "*CURVE" and kw_upper ~= "*TABLE" then
                  if pn:match("^[xyz]_[%w_]*$") or pn == "x" or pn == "y" or pn == "z"
                    or pn:match("^v[xyz]?$") or pn:match("^velo") or pn:match("^velocity")
                    or pn == "m" or pn == "mass" then
                    check_numeric_field(val, param_name, j, field_col_from_idx(lines[j], fi))
                  end
                end
              end
            end
          end
        end
      end

      i = end_i
    end
    i = i + 1
  end
end

-- =====================================================================
-- Enum value checks
-- =====================================================================

local function check_enum_values(ctx, diagnostics)
  local lines = ctx.lines
  local db = ctx.db

  local i = 1
  while i <= #lines do
    local kw = trim(lines[i] or ""):match("^(%*[%u%d_%-]+)")
    if kw then
      local kw_upper = kw:upper()
      local entry = db[kw]
      if entry and entry.signature_rows and #entry.signature_rows > 0 then
        local start_i = i
        local end_i = #lines
        for j = i + 1, #lines do
          if trim(lines[j] or ""):match("^(%*[%u%d_%-]+)") then
            end_i = j - 1
            break
          end
        end

        local data_rows = {}
        for j = start_i + 1, end_i do
          local t = trim(lines[j] or "")
          local is_title = t:match('^".*"$') ~= nil
          -- Empty lines inside a keyword block are legal data rows (all defaults)
          if t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" and t:sub(1, 1) ~= "~" and not is_title then
            data_rows[#data_rows + 1] = j
          end
        end
        local sig = entry.signature_rows
        local desc = entry.descriptions or {}

        local id_row_omitted = false
        for dr_idx, row in ipairs(data_rows) do
          -- *PARAMETER / *PARAMETER_DEFAULT may contain quoted descriptions with commas
          local fields = (kw_upper == "*PARAMETER" or kw_upper == "*PARAMETER_DEFAULT")
            and split_csv_outside_quotes(lines[row])
            or split_csv_keep_empty(lines[row])
          local schema_row = nil

          -- Detect omitted optional ID row (same logic as check_field_counts)
          if dr_idx == 1 then
            local sig1 = sig[1]
            if sig1 and #sig1 == 1 and #sig >= 2 then
              local first_val = trim(lines[row]:match("^([^,]+)") or "")
              if not (
                first_val:match("^[+-]?%d+$")
                or first_val:match("^[+-]?%d+%.0+$")
                or first_val:match("^%%[%w_]+$")
                or first_val:match("^%[%%[%w_]+%]$")
              ) then
                local first_param = sig1[1] or ""
                local is_id_like = first_param:match("^%d+$") or first_param:match("^[%a_]*[iI][dD]$")
                if is_id_like then
                  schema_row = sig[2]
                  id_row_omitted = true
                end
              end
            end
          end
          if not schema_row then
            local sig_idx = id_row_omitted and (dr_idx + 1) or dr_idx
            schema_row = sig[sig_idx] or sig[#sig]
          end

          for fi, param_name in ipairs(schema_row or {}) do
            local val = trim(fields[fi] or "")
            if val ~= "" and val ~= "-" then
              -- Skip parameter references and expressions
              -- *PARAMETER descriptions may contain commas and operators; skip them
              local is_param_description = (kw_upper == "*PARAMETER" or kw_upper == "*PARAMETER_DEFAULT")
                and (val:find("=") or val:match('^".*"$'))
              if not is_param_description and not (val:match("^%%[%w_]+$") or val:match("^%[%%[%w_]+%]$") or val:find("[%+%-%*/%(%)]")) then
                if kw_upper == "*CFD_HE" and param_name == "type" then
                  -- skip enum check: preset names / user / mat ids are all valid
                else
                  local enum_arr = schema.generic_enum_for_name(param_name)
                  local opts = nil
                  if kw:upper() == "*UNIT_SYSTEM" and param_name == "units" then
                    opts = {}
                    for k, _ in pairs(unit_system_aliases) do
                      opts[k] = true
                    end
                  elseif kw:upper() == "*PARTICLE_DOMAIN" and param_name == "entype" then
                    -- *PARTICLE_DOMAIN entype allows 0 (no interaction) in addition to standard entity types
                    opts = extract_options_from_desc(find_desc_for_param(desc, param_name))
                  elseif enum_arr then
                    opts = {}
                    for _, v in ipairs(enum_arr) do
                      opts[v:upper()] = true
                    end
                  else
                    opts = extract_options_from_desc(find_desc_for_param(desc, param_name))
                  end
                  if opts then
                    local check_val = val:upper()
                    if not opts[check_val] then
                      -- Special handling for "constant" / "fcn" options:
                      -- "constant" means a numeric literal is acceptable.
                      -- "fcn" means a function reference (e.g. fcn(5)) is acceptable.
                      local has_constant = opts["CONSTANT"]
                      local has_fcn = opts["FCN"]
                      local is_valid = false
                      if has_constant and to_number(val) then
                        is_valid = true
                      end
                      if has_fcn then
                        local vlow = val:lower()
                        if vlow:match("^fcn%s*%b()") or vlow:match("^%d+$") then
                          is_valid = true
                        end
                      end
                      if not is_valid then
                        -- Also try numeric match (e.g. user wrote 1 instead of "1")
                        local num = tonumber(val)
                        if num then
                          local in_range = true
                          if opts.__gt__ and num <= opts.__gt__ then in_range = false end
                          if opts.__ge__ and num < opts.__ge__ then in_range = false end
                          if opts.__lt__ and num >= opts.__lt__ then in_range = false end
                          if opts.__le__ and num > opts.__le__ then in_range = false end
                          if in_range then
                            is_valid = true
                          end
                        end
                        if not is_valid then
                          if not num or not opts[tostring(num)] then
                            local opt_list = {}
                            for k, _ in pairs(opts) do
                              if not k:match("^__") then
                                opt_list[#opt_list + 1] = k
                              end
                            end
                            table.sort(opt_list)
                            push_diagnostic(
                              diagnostics,
                              row - 1,
                              field_col_from_idx(lines[row], fi),
                              SEV.ERROR,
                              "Invalid value '" .. val .. "' for field '" .. param_name .. "' in " .. kw
                                .. ". Expected: " .. table.concat(opt_list, ", ")
                            )
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
        i = end_i
      end
    end
    i = i + 1
  end
end

-- =====================================================================
-- Main run function
-- =====================================================================

function M.run(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local db = store.get_db()
  local diagnostics = {}

  -- Detect unit system
  local unit_system, _ = get_unit_system(lines)
  local seen_unit_system = unit_system ~= nil

  -- Build index once
  local idx = analysis.build_buffer_index(bufnr)

  -- Detect if file contains *INCLUDE
  local has_include = false
  for _, raw in ipairs(lines) do
    if trim(raw):match("^%*INCLUDE") then
      has_include = true
      break
    end
  end

  -- Collect part IDs referenced by *GEOMETRY_PART (these parts don't need material)
  local geometry_part_pids = {}
  local gi = 1
  while gi <= #lines do
    local kw = trim(lines[gi] or ""):match("^(%*[%u%d_%-]+)")
    if kw and kw:upper() == "*GEOMETRY_PART" then
      local end_i = #lines
      for j = gi + 1, #lines do
        if trim(lines[j] or ""):match("^(%*[%u%d_%-]+)") then
          end_i = j - 1
          break
        end
      end
      local data_row_count = 0
      for j = gi + 1, end_i do
        local t = trim(lines[j] or "")
        local is_title = t:match('^".*"$') ~= nil
        -- Empty lines inside a keyword block are legal data rows (all defaults)
        if t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" and t:sub(1, 1) ~= "~" and not is_title then
          data_row_count = data_row_count + 1
          if data_row_count == 2 then
            local fields = split_csv_keep_empty(t)
            local pid = trim(fields[1] or "")
            if pid ~= "" and pid ~= "-" then
              geometry_part_pids[pid] = true
            end
            break
          end
        end
      end
      gi = end_i
    end
    gi = gi + 1
  end

  local cross_file_params = analysis.build_cross_file_param_index(bufnr)
  local cross_file_objects = analysis.build_cross_file_object_index(bufnr)

  -- Detect if file (or any included file) contains *PARTICLE_* or *CFD_* keywords
  local has_particle = false
  local has_cfd = false
  for kw, _ in pairs(cross_file_objects.keywords or {}) do
    if kw:match("^%*PARTICLE") then
      has_particle = true
    end
    if kw:match("^%*CFD") then
      has_cfd = true
    end
  end

  -- Detect if *TIME exists and its first parameter (t_term) has a value.
  -- When *TIME t_term is present, *OUTPUT's first three parameters get
  -- defaults (t_term/100, t_term/1000, t_term/1) and should not be flagged.
  local has_time_with_t_term = false
  for i, line in ipairs(lines) do
    local kw = trim(line):match("^%*[%w_]+")
    if kw and kw:upper() == "*TIME" then
      -- Skip blank/comment lines to find the first data row
      local scan = i + 1
      while scan <= #lines do
        local l = lines[scan] or ""
        if trim(l) == "" or l:match("^%s*#") then
          scan = scan + 1
        else
          break
        end
      end
      if scan <= #lines then
        local time_fields = split_csv_keep_empty(lines[scan])
        if trim(time_fields[1] or "") ~= "" and trim(time_fields[1] or "") ~= "-" then
          has_time_with_t_term = true
        end
      end
      break
    end
  end

  -- Collect *MAT_EXPLOSIVE_JWL ids for *CFD_HE validation
  local mat_explosive_jwl_ids = {}
  for id, def in pairs(idx.object_defs.material or {}) do
    if def.keyword == "*MAT_EXPLOSIVE_JWL" then
      mat_explosive_jwl_ids[id] = true
    end
  end
  for id, def in pairs(cross_file_objects.defs and cross_file_objects.defs.material or {}) do
    if def.keyword == "*MAT_EXPLOSIVE_JWL" then
      mat_explosive_jwl_ids[id] = true
    end
  end

  local ctx = {
    bufnr = bufnr,
    lines = lines,
    db = db,
    idx = idx,
    seen_unit_system = seen_unit_system,
    unit_system = unit_system,
    has_include = has_include,
    geometry_part_pids = geometry_part_pids,
    cross_file_params = cross_file_params,
    cross_file_objects = cross_file_objects,
    has_particle = has_particle,
    has_cfd = has_cfd,
    has_time_with_t_term = has_time_with_t_term,
    mat_explosive_jwl_ids = mat_explosive_jwl_ids,
  }

  -- Configure namespace signs/virtual_text
  vim.diagnostic.config({
    virtual_text = {
      prefix = "●",
      format = function(d)
        if d.severity == SEV.SUSPICION then
          return "[Suspicion] " .. d.message
        end
        return d.message
      end,
    },
    signs = {
      text = {
        [SEV.ERROR] = "E",
        [SEV.WARNING] = "W",
        [SEV.SUSPICION] = "?",
      },
    },
  }, ns)

  -- Run all checks
  check_control_blocks(ctx, diagnostics)
  check_unknown_keywords(ctx, diagnostics)
  check_field_counts(ctx, diagnostics)
  check_param_refs(ctx, diagnostics)
  check_unused_params(ctx, diagnostics)
  check_duplicate_ids(ctx, diagnostics)
  check_missing_includes(ctx, diagnostics)
  check_empty_blocks(ctx, diagnostics)
  check_object_refs_valid(ctx, diagnostics)
  check_unused_curves(ctx, diagnostics)
  check_required_fields(ctx, diagnostics)
  check_enum_values(ctx, diagnostics)
  check_physics_sanity(ctx, diagnostics)

  -- Missing unit system warning (only if the file has material or geometry keywords)
  if not unit_system then
    local has_physics = false
    for _, k in ipairs(idx.keywords or {}) do
      local kw = k.keyword:upper()
      if kw:match("^%*MAT_") or kw:match("^%*PART") or kw:match("^%*LOAD") then
        has_physics = true
        break
      end
    end
    if has_physics then
      push_diagnostic(diagnostics, 0, 0, SEV.WARNING, "No *UNIT_SYSTEM found; physical sanity checks skipped")
    end
  end

  vim.diagnostic.set(ns, bufnr, diagnostics, {})
  return diagnostics
end

return M
