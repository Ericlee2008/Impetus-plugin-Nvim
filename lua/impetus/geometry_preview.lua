local config = require("impetus.config")
local analysis = require("impetus.analysis")

local M = {}

-- =====================================================================
-- Basic string helpers
-- =====================================================================
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

-- =====================================================================
-- Parameter resolution
-- =====================================================================
local function normalize_param_name(s)
  return ((s or ""):gsub("^%%", ""):gsub("^%[", ""):gsub("%]$", ""))
end

local function to_number(s)
  local t = trim(s or "")
  if t == "" then return nil end
  local n = tonumber(t)
  if n then return n end
  if t:match("^0[xX]%x+$") then return tonumber(t, 16) end
  return nil
end

local function resolve_param_value(name, all_defs)
  local key = normalize_param_name(name)
  local defs = all_defs and (all_defs[key] or all_defs[key:lower()])
  if not defs or #defs == 0 then
    return nil
  end
  local line = defs[1].line or ""
  -- Extract value from "name = value, "desc"" or "name, value, "desc""
  local value = line:match("=%s*([^,]+)")
  if not value then
    value = line:match(",%s*([^,]+)")
  end
  if value then
    value = trim(value)
    local num = to_number(value)
    if num then return num end
    local ref_name = value:match("^%%([%a_][%w_]*)$") or value:match("^%[%%([%a_][%w_]*)%]$")
    if ref_name then
      return resolve_param_value(ref_name, all_defs)
    end
  end
  return nil
end

local function extract_values(line, all_defs)
  local out = {}
  for token in (line or ""):gmatch("[^,%s]+") do
    local num = to_number(token)
    if num then
      out[#out + 1] = num
    else
      local name = token:match("^%%([%a_][%w_]*)$") or token:match("^%[%%([%a_][%w_]*)%]$")
      if name then
        local val = resolve_param_value(name, all_defs)
        if val then
          out[#out + 1] = val
        end
      end
    end
  end
  return out
end

-- =====================================================================
-- Block finding
-- =====================================================================
local function find_block(lines, row)
  local start_row, keyword = nil, nil
  for r = row, 1, -1 do
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
    if parse_keyword(lines[r] or "") then
      end_row = r - 1
      break
    end
  end
  return { keyword = keyword, start_row = start_row, end_row = end_row }
end

local function is_meta_line(line)
  local normalized = trim(strip_number_prefix(line or ""))
  if normalized == "" then return true end
  if normalized:sub(1, 1) == "#" or normalized:sub(1, 1) == "$" then return true end
  if normalized:sub(1, 1) == "~" then return true end
  if normalized:match("^%-+$") then return true end
  if normalized == "Variable         Description" then return true end
  if normalized == '"Optional title"' or normalized:match('^".*"$') then return true end
  return false
end

local function get_data_lines(block_lines)
  local out = {}
  for _, line in ipairs(block_lines) do
    local t = trim(strip_number_prefix(line or ""))
    -- Skip keyword lines (start with *) in addition to meta lines
    if not is_meta_line(line) and t:sub(1, 1) ~= "*" then
      out[#out + 1] = line
    end
  end
  return out
end

-- =====================================================================
-- Coordinate system lookup
-- =====================================================================
local function find_coordinate_system(lines, cid)
  if not cid or cid == 0 then return nil end
  local in_block = false
  local block_lines = {}
  for _, line in ipairs(lines) do
    local t = trim(line)
    if t:match("^%*COORDINATE_SYSTEM") then
      in_block = true
      block_lines = {}
    elseif t:match("^%*") and in_block then
      in_block = false
      if #block_lines > 0 then
        local nums = {}
        for token in block_lines[1]:gmatch("[^,%s]+") do
          local n = to_number(token)
          if n then nums[#nums + 1] = n end
        end
        if nums[1] == cid then
          return block_lines
        end
      end
    elseif in_block then
      block_lines[#block_lines + 1] = line
    end
  end
  if in_block and #block_lines > 0 then
    local nums = {}
    for token in block_lines[1]:gmatch("[^,%s]+") do
      local n = to_number(token)
      if n then nums[#nums + 1] = n end
    end
    if nums[1] == cid then
      return block_lines
    end
  end
  return nil
end

-- =====================================================================
-- Shape detection
-- =====================================================================
local function shape_from_keyword(keyword)
  local k = (keyword or ""):lower()
  if k:find("sphere", 1, true) then return "sphere" end
  if k:find("cyl", 1, true) then return "cylinder" end
  if k:find("box", 1, true) then return "box" end
  if k:find("ellip", 1, true) then return "ellipsoid" end
  if k:find("pipe", 1, true) then return "pipe" end
  if k:find("efp", 1, true) then return "efp" end
  return nil
end

-- =====================================================================
-- Payload builders per keyword
-- =====================================================================
local function build_component_box_payload(kw, block_lines, all_defs, buf_lines)
  local data_lines = get_data_lines(block_lines)
  if #data_lines < 2 then
    return nil, "*COMPONENT_BOX needs at least 2 data rows"
  end
  local first_vals = extract_values(data_lines[1], all_defs)
  local second_vals = extract_values(data_lines[2], all_defs)
  if not first_vals or #first_vals < 5 then
    return nil, "*COMPONENT_BOX row 1 needs at least 5 values"
  end
  if not second_vals or #second_vals < 6 then
    return nil, "*COMPONENT_BOX row 2 needs at least 6 values"
  end
  local split_x = math.max(1, math.floor(first_vals[3] or 1))
  local split_y = math.max(1, math.floor(first_vals[4] or 1))
  local split_z = math.max(1, math.floor(first_vals[5] or 1))
  local cid = first_vals[6]
  local points = {
    { second_vals[1], second_vals[2], second_vals[3] },
    { second_vals[4], second_vals[5], second_vals[6] },
  }
  local payload = {
    keyword = kw,
    shape = "box",
    points = points,
    numbers = { second_vals[1], second_vals[2], second_vals[3], second_vals[4], second_vals[5], second_vals[6] },
    splits = { split_x, split_y, split_z },
    coordinate_system = cid,
  }
  if cid and cid ~= 0 and buf_lines then
    local cs_lines = find_coordinate_system(buf_lines, cid)
    if cs_lines then
      local cs_vals = {}
      for _, line in ipairs(cs_lines) do
        local vals = extract_values(line, all_defs)
        for _, v in ipairs(vals) do
          cs_vals[#cs_vals + 1] = v
        end
      end
      payload.coordinate_system_lines = cs_lines
      payload.coordinate_system_values = cs_vals
    end
  end
  return payload
end

local function build_component_sphere_payload(kw, block_lines, all_defs)
  local data_lines = get_data_lines(block_lines)
  if #data_lines < 2 then
    return nil, "*COMPONENT_SPHERE needs at least 2 data rows"
  end
  local second_vals = extract_values(data_lines[2], all_defs)
  if not second_vals or #second_vals < 4 then
    return nil, "*COMPONENT_SPHERE row 2 needs at least 4 values"
  end
  local points = { { second_vals[1], second_vals[2], second_vals[3] } }
  return {
    keyword = kw,
    shape = "sphere",
    points = points,
    numbers = second_vals,
    scalars = { second_vals[4] },
  }
end

local function build_component_cylinder_payload(kw, block_lines, all_defs)
  local data_lines = get_data_lines(block_lines)
  if #data_lines < 2 then
    return nil, "*COMPONENT_CYLINDER needs at least 2 data rows"
  end
  local second_vals = extract_values(data_lines[2], all_defs)
  if not second_vals or #second_vals < 8 then
    return nil, "*COMPONENT_CYLINDER row 2 needs at least 8 values"
  end
  local points = {
    { second_vals[1], second_vals[2], second_vals[3] },
    { second_vals[4], second_vals[5], second_vals[6] },
  }
  return {
    keyword = kw,
    shape = "cylinder",
    points = points,
    numbers = second_vals,
    scalars = { second_vals[7] },
  }
end

local function build_geometry_box_payload(kw, block_lines, all_defs)
  local data_lines = get_data_lines(block_lines)
  if #data_lines < 2 then
    return nil, kw .. " needs at least 2 data rows"
  end
  local second_vals = extract_values(data_lines[2], all_defs)
  if not second_vals or #second_vals < 5 then
    return nil, kw .. " row 2 needs at least 5 values"
  end
  local points = {
    { second_vals[1], second_vals[2], second_vals[3] },
    { second_vals[4], second_vals[5], second_vals[6] or second_vals[5] },
  }
  return {
    keyword = kw,
    shape = "box",
    points = points,
    numbers = second_vals,
  }
end

local function build_geometry_sphere_payload(kw, block_lines, all_defs)
  local data_lines = get_data_lines(block_lines)
  if #data_lines < 2 then
    return nil, kw .. " needs at least 2 data rows"
  end
  local second_vals = extract_values(data_lines[2], all_defs)
  if not second_vals or #second_vals < 4 then
    return nil, kw .. " row 2 needs at least 4 values"
  end
  local points = { { second_vals[1], second_vals[2], second_vals[3] } }
  return {
    keyword = kw,
    shape = "sphere",
    points = points,
    numbers = second_vals,
    scalars = { second_vals[4] },
  }
end

local function build_geometry_pipe_payload(kw, block_lines, all_defs)
  local data_lines = get_data_lines(block_lines)
  if #data_lines < 3 then
    return nil, "*GEOMETRY_PIPE needs at least 3 data rows"
  end
  local second_vals = extract_values(data_lines[2], all_defs)
  local third_vals = extract_values(data_lines[3], all_defs)
  if not second_vals or #second_vals < 8 then
    return nil, "*GEOMETRY_PIPE row 2 needs at least 8 values"
  end
  if not third_vals or #third_vals < 6 then
    return nil, "*GEOMETRY_PIPE row 3 needs at least 6 values"
  end
  local all = {}
  for _, v in ipairs(second_vals) do all[#all + 1] = v end
  for _, v in ipairs(third_vals) do all[#all + 1] = v end
  return {
    keyword = kw,
    shape = "cylinder",
    points = {
      { second_vals[1], second_vals[2], second_vals[3] },
      { second_vals[4], second_vals[5], second_vals[6] },
    },
    numbers = all,
    scalars = { second_vals[7] },
  }
end

local function build_generic_payload(kw, block_lines, all_defs)
  local shape = shape_from_keyword(kw)
  if not shape then
    return nil, "could not infer geometry shape from '" .. kw .. "'"
  end
  local points = {}
  local scalars = {}
  local numbers = {}
  for _, line in ipairs(block_lines) do
    if not is_meta_line(line) then
      local vals = extract_values(line, all_defs)
      for _, v in ipairs(vals) do
        numbers[#numbers + 1] = v
      end
      if #vals == 1 then
        scalars[#scalars + 1] = vals[1]
      end
      local i = 1
      while i + 2 <= #vals do
        points[#points + 1] = { vals[i], vals[i + 1], vals[i + 2] }
        i = i + 3
      end
    end
  end
  return {
    keyword = kw,
    shape = shape,
    points = points,
    scalars = scalars,
    numbers = numbers,
  }
end

-- =====================================================================
-- Main payload builder
-- =====================================================================
local function build_payload(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local block = find_block(lines, row)
  if not block then
    return nil, "no keyword block under cursor"
  end

  local block_lines = {}
  for r = block.start_row, block.end_row do
    block_lines[#block_lines + 1] = lines[r] or ""
  end

  -- Build parameter index for resolving %param / [%param] references
  local param_idx = analysis.build_cross_file_param_index(bufnr)
  local all_defs = param_idx.defs or {}

  local kw = (block.keyword or ""):upper()
  local payload, err

  if kw == "*COMPONENT_BOX" then
    payload, err = build_component_box_payload(kw, block_lines, all_defs, lines)
  elseif kw == "*COMPONENT_SPHERE" then
    payload, err = build_component_sphere_payload(kw, block_lines, all_defs)
  elseif kw == "*COMPONENT_CYLINDER" then
    payload, err = build_component_cylinder_payload(kw, block_lines, all_defs)
  elseif kw == "*GEOMETRY_BOX" then
    payload, err = build_geometry_box_payload(kw, block_lines, all_defs)
  elseif kw == "*GEOMETRY_SPHERE" or kw == "*GEOMETRY_ELLIPSOID" then
    payload, err = build_geometry_sphere_payload(kw, block_lines, all_defs)
  elseif kw == "*GEOMETRY_PIPE" then
    payload, err = build_geometry_pipe_payload(kw, block_lines, all_defs)
  else
    payload, err = build_generic_payload(kw, block_lines, all_defs)
  end

  if not payload then
    return nil, err
  end

  payload.file = vim.api.nvim_buf_get_name(bufnr)
  payload.cursor_row = row
  payload.block = {
    start_row = block.start_row,
    end_row = block.end_row,
    lines = block_lines,
  }
  return payload
end

-- =====================================================================
-- Viewer launch
-- =====================================================================
local function repo_root()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  return vim.fn.fnamemodify(src, ":p:h:h:h")
end

function M.open_current()
  local payload, err = build_payload(0)
  if not payload then
    return false, err
  end

  -- Debug: show payload summary
  local pts_info = ""
  if payload.points and #payload.points > 0 then
    pts_info = string.format(", points=%d (first=%s)", #payload.points,
      vim.inspect(payload.points[1]))
  end
  vim.notify(string.format("[geometry_preview] %s | shape=%s%s",
    payload.keyword, payload.shape or "?", pts_info), vim.log.levels.INFO)

  local opts = config.get().geometry_preview or {}
  local script = opts.viewer_script
  if not script or script == "" then
    script = repo_root() .. "/scripts/impetus_geometry_viewer.py"
  end
  if vim.fn.filereadable(script) ~= 1 then
    return false, "viewer script not found: " .. script
  end

  local payload_path = vim.fn.tempname() .. "_impetus_geometry.json"
  local json = vim.json.encode(payload)
  vim.fn.writefile({ json }, payload_path)

  -- Also write to a fixed path for manual inspection
  local debug_path = vim.fn.stdpath("cache") .. "/impetus_geometry_preview.json"
  vim.fn.writefile({ json }, debug_path)

  local python = opts.python_exe or "python"
  local args = opts.python_args or {}
  local cmd = { python }
  for _, a in ipairs(args) do
    cmd[#cmd + 1] = a
  end
  cmd[#cmd + 1] = script
  cmd[#cmd + 1] = payload_path

  local cmd_str = table.concat(cmd, " ")
  vim.notify("[geometry_preview] cmd: " .. cmd_str, vim.log.levels.INFO)

  local stderr_lines = {}
  local ret = vim.fn.jobstart(cmd, {
    detach = true,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            stderr_lines[#stderr_lines + 1] = line
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        local msg = table.concat(stderr_lines, "\n")
        vim.schedule(function()
          vim.notify("[geometry_preview] viewer exited with code " .. code .. ":\n" .. msg, vim.log.levels.ERROR)
        end)
      end
    end,
  })
  if ret <= 0 then
    return false, "failed to launch geometry viewer (jobstart returned " .. tostring(ret) .. ")"
  end
  vim.notify("[geometry_preview] viewer launched (job id=" .. ret .. ")", vim.log.levels.INFO)
  return true
end

return M
