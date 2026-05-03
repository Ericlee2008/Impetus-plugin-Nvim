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

local function is_mesh_keyword(keyword)
  local k = (keyword or ""):upper()
  return k:find("^%*ELEMENT_SOLID") ~= nil or k == "*NODE"
end

local function is_geometry_keyword(keyword)
  -- Exclude mesh keywords so *NODE/*ELEMENT_SOLID aren't treated as geometry
  if is_mesh_keyword(keyword) then return false end
  return shape_from_keyword(keyword) ~= nil
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
        else
          vim.notify("[geometry_preview] unresolved param: %" .. name, vim.log.levels.WARN)
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

local function find_all_geometry_blocks(lines)
  local blocks = {}
  local i = 1
  while i <= #lines do
    local kw = parse_keyword(lines[i] or "")
    if kw then
      local start_row = i
      local end_row = #lines
      for r = i + 1, #lines do
        if parse_keyword(lines[r] or "") then
          end_row = r - 1
          break
        end
      end
      if is_geometry_keyword(kw) then
        blocks[#blocks + 1] = { keyword = kw, start_row = start_row, end_row = end_row }
      end
      i = end_row + 1
    else
      i = i + 1
    end
  end
  return blocks
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
    id = first_vals[1],
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
  local first_vals = extract_values(data_lines[1], all_defs)
  return {
    keyword = kw,
    id = first_vals and first_vals[1] or nil,
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
  local first_vals = extract_values(data_lines[1], all_defs)
  return {
    keyword = kw,
    id = first_vals and first_vals[1] or nil,
    shape = "cylinder",
    points = points,
    numbers = second_vals,
    scalars = { second_vals[7] },
  }
end

local function build_component_pipe_payload(kw, block_lines, all_defs)
  local data_lines = get_data_lines(block_lines)
  if #data_lines < 2 then
    return nil, "*COMPONENT_PIPE needs at least 2 data rows"
  end
  local first_vals = extract_values(data_lines[1], all_defs)
  local second_vals = extract_values(data_lines[2], all_defs)
  if not second_vals or #second_vals < 8 then
    return nil, "*COMPONENT_PIPE row 2 needs at least 8 values"
  end
  local points = {
    { second_vals[1], second_vals[2], second_vals[3] },
    { second_vals[4], second_vals[5], second_vals[6] },
  }
  local inner = second_vals[7]
  local outer = second_vals[8]
  -- inner radius == 0 means solid cylinder
  if inner == 0 then
    return {
      keyword = kw,
      id = first_vals and first_vals[1] or nil,
      shape = "cylinder",
      points = points,
      numbers = second_vals,
      scalars = { outer },
    }
  end
  return {
    keyword = kw,
    id = first_vals and first_vals[1] or nil,
    shape = "pipe",
    points = points,
    numbers = second_vals,
    scalars = { inner, outer },
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
  local first_vals = extract_values(data_lines[1], all_defs)
  return {
    keyword = kw,
    id = first_vals and first_vals[1] or nil,
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
  local first_vals = extract_values(data_lines[1], all_defs)
  return {
    keyword = kw,
    id = first_vals and first_vals[1] or nil,
    shape = "sphere",
    points = points,
    numbers = second_vals,
    scalars = { second_vals[4] },
  }
end

local function build_geometry_pipe_payload(kw, block_lines, all_defs)
  local data_lines = get_data_lines(block_lines)
  if #data_lines < 2 then
    return nil, "*GEOMETRY_PIPE needs at least 2 data rows"
  end
  local second_vals = extract_values(data_lines[2], all_defs)
  if not second_vals or #second_vals < 7 then
    return nil, "*GEOMETRY_PIPE row 2 needs at least 7 values"
  end
  local points = {
    { second_vals[1], second_vals[2], second_vals[3] },
    { second_vals[4], second_vals[5], second_vals[6] },
  }
  local scalars = { second_vals[7] }
  -- r2 (other end outer radius) optional in row 2 col 8
  if #second_vals >= 8 then
    scalars[2] = second_vals[8]
  end
  -- row 3: [other_end_outer_radius, inner_radius]
  if #data_lines >= 3 then
    local third_vals = extract_values(data_lines[3], all_defs)
    if third_vals and #third_vals >= 1 then
      scalars[2] = third_vals[1]  -- override r2
    end
    if third_vals and #third_vals >= 2 then
      scalars[3] = third_vals[2]  -- inner radius
    end
  end
  local first_vals = extract_values(data_lines[1], all_defs)
  return {
    keyword = kw,
    id = first_vals and first_vals[1] or nil,
    shape = "pipe",
    points = points,
    scalars = scalars,
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
local function build_payload_for_block(bufnr, lines, block, all_defs)
  local block_lines = {}
  for r = block.start_row, block.end_row do
    block_lines[#block_lines + 1] = lines[r] or ""
  end

  local kw = (block.keyword or ""):upper()
  local payload, err

  if kw == "*COMPONENT_BOX" then
    payload, err = build_component_box_payload(kw, block_lines, all_defs, lines)
  elseif kw == "*COMPONENT_SPHERE" then
    payload, err = build_component_sphere_payload(kw, block_lines, all_defs)
  elseif kw == "*COMPONENT_CYLINDER" then
    payload, err = build_component_cylinder_payload(kw, block_lines, all_defs)
  elseif kw == "*COMPONENT_PIPE" then
    payload, err = build_component_pipe_payload(kw, block_lines, all_defs)
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
  payload.block = {
    start_row = block.start_row,
    end_row = block.end_row,
    lines = block_lines,
  }
  return payload
end

local function build_payload(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local block = find_block(lines, row)
  if not block then
    return nil, "no keyword block under cursor"
  end

  local param_idx = analysis.build_cross_file_param_index(bufnr)
  local all_defs = param_idx.defs or {}

  local payload, err = build_payload_for_block(bufnr, lines, block, all_defs)
  if not payload then
    return nil, err
  end

  payload.cursor_row = row
  return payload
end

-- =====================================================================
-- Mesh payload builder (ELEMENT_SOLID + NODE)
-- =====================================================================
local function build_mesh_payload(bufnr, lines)
  local nodes = {}   -- [nid] = {x, y, z}
  local elements = {} -- { eid, pid, etype, nodes }

  local i = 1
  while i <= #lines do
    local kw = parse_keyword(lines[i] or "")
    if kw then
      local kw_upper = kw:upper()
      local end_row = #lines
      for r = i + 1, #lines do
        if parse_keyword(lines[r] or "") then
          end_row = r - 1
          break
        end
      end

      if kw_upper == "*NODE" then
        -- Parse node block
        for r = i + 1, end_row do
          local line = lines[r] or ""
          if not is_meta_line(line) then
            local vals = extract_values(line, nil)  -- no param resolution for nodes
            if vals and #vals >= 4 then
              local nid = math.floor(vals[1])
              nodes[tostring(nid)] = { vals[2], vals[3], vals[4] }
            end
          end
        end
      elseif kw_upper:find("^%*ELEMENT_SOLID") then
        -- Parse element block
        for r = i + 1, end_row do
          local line = lines[r] or ""
          if not is_meta_line(line) then
            local vals = extract_values(line, nil)
            if vals and #vals >= 3 then
              local eid = math.floor(vals[1])
              local pid = math.floor(vals[2])
              local node_ids = {}
              for j = 3, #vals do
                node_ids[#node_ids + 1] = math.floor(vals[j])
              end
              local etype
              if #node_ids == 8 then
                etype = "hex"
              elseif #node_ids == 6 then
                etype = "penta"
              elseif #node_ids == 4 then
                etype = "tetra"
              else
                etype = "hex"  -- default
              end
              elements[#elements + 1] = {
                eid = eid,
                pid = pid,
                etype = etype,
                nodes = node_ids,
              }
            end
          end
        end
      end
      i = end_row + 1
    else
      i = i + 1
    end
  end

  if #elements == 0 then
    return nil
  end

  return {
    type = "mesh",
    nodes = nodes,
    elements = elements,
    file = vim.api.nvim_buf_get_name(bufnr),
  }
end

local function build_all_payloads(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Collect mesh data FIRST (independent of geometry blocks)
  local mesh_payload = build_mesh_payload(bufnr, lines)

  local blocks = find_all_geometry_blocks(lines)

  -- Fail only if NEITHER geometry nor mesh data exists
  if #blocks == 0 and not mesh_payload then
    return nil, "no geometry or mesh keyword blocks found in current file"
  end

  local param_idx = analysis.build_cross_file_param_index(bufnr)
  local all_defs = param_idx.defs or {}

  local payloads = {}
  local errors = {}
  for _, block in ipairs(blocks) do
    local payload, err = build_payload_for_block(bufnr, lines, block, all_defs)
    if payload then
      payloads[#payloads + 1] = payload
    else
      errors[#errors + 1] = block.keyword .. " (row " .. block.start_row .. "): " .. (err or "unknown error")
    end
  end

  -- Append mesh data to payloads
  if mesh_payload then
    payloads[#payloads + 1] = mesh_payload
    vim.notify(string.format("[geometry_preview] mesh: %d nodes, %d elements",
      vim.tbl_count(mesh_payload.nodes or {}), #mesh_payload.elements), vim.log.levels.INFO)
  end

  if #payloads == 0 then
    return nil, "no valid geometry or mesh payloads built:\n" .. table.concat(errors, "\n")
  end

  return payloads, (#errors > 0 and table.concat(errors, "\n") or nil)
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

M._viewer_job = nil
M._viewer_script = nil

-- Resolve py/pyw launcher to the actual python.exe on Windows
local function resolve_python_exe(opts)
  local exe = opts.python_exe or "python"
  local args = opts.python_args or {}
  if exe == "py" or exe == "pyw" then
    local launcher = exe
    local ver = (#args > 0 and args[1]) or "-3"
    local handle = io.popen(launcher .. " " .. ver .. ' -c "import sys; print(sys.executable)"')
    if handle then
      local path = vim.fn.trim(handle:read("*a") or "")
      handle:close()
      if path ~= "" and vim.fn.filereadable(path) == 1 then
        -- Use the actual python.exe, drop the launcher args
        return path, {}
      end
    end
  end
  return exe, args
end

function M.close_viewer()
  if M._viewer_job and M._viewer_job > 0 then
    pcall(vim.fn.chansend, M._viewer_job, vim.json.encode({ cmd = "exit" }) .. "\n")
    -- Always stop the job and clear the reference; the process may hang
    -- even if chansend appeared to succeed.
    vim.wait(300, function() return false end, 10)
    pcall(vim.fn.jobstop, M._viewer_job)
    M._viewer_job = nil
  end
end

function M.open_current()
  local payloads, err = build_all_payloads(0)
  if not payloads then
    return false, err
  end

  local shapes = {}
  for _, p in ipairs(payloads) do
    shapes[#shapes + 1] = p.keyword
  end
  vim.notify(string.format("[geometry_preview] showing %d objects: %s",
    #payloads, table.concat(shapes, ", ")), vim.log.levels.INFO)

  local opts = config.get().geometry_preview or {}
  local script = opts.viewer_script
  if not script or script == "" then
    script = repo_root() .. "/scripts/impetus_geometry_viewer.py"
  end
  if vim.fn.filereadable(script) ~= 1 then
    return false, "viewer script not found: " .. script
  end
  M._viewer_script = script

  -- Pack all payloads for the viewer
  local all_payload = {
    objects = payloads,
    file = vim.api.nvim_buf_get_name(0),
    cursor_row = vim.api.nvim_win_get_cursor(0)[1],
  }

  local json = vim.json.encode(all_payload)
  -- Also write to a fixed path for manual inspection
  local debug_path = vim.fn.stdpath("cache") .. "/impetus_geometry_preview.json"
  vim.fn.writefile({ json }, debug_path)

  local need_start = false
  if not M._viewer_job or M._viewer_job <= 0 then
    need_start = true
  else
    local ok, pid = pcall(vim.fn.jobpid, M._viewer_job)
    if not ok or pid <= 0 then
      need_start = true
    end
  end

  if need_start then
    -- Always clear previous job reference first
    M._viewer_job = nil
    -- Kill any stale viewer processes before launching a new one
    vim.fn.system('taskkill /F /IM pythonw.exe 2>nul')
    vim.fn.system('taskkill /F /IM python.exe /FI "WINDOWTITLE eq Impetus Geometry Preview*" 2>nul')
    vim.fn.system('taskkill /F /IM python.exe /FI "WINDOWTITLE eq ImpetusVTK*" 2>nul')

    local python, py_args = resolve_python_exe(opts)
    local cmd = { python }
    for _, a in ipairs(py_args) do
      cmd[#cmd + 1] = a
    end
    cmd[#cmd + 1] = script

    M._viewer_job = vim.fn.jobstart(cmd, {
      detach = true,
      stderr_buffered = false,
      on_exit = function(_, code)
        M._viewer_job = nil
        if code ~= 0 then
          vim.schedule(function()
            vim.notify("[geometry_preview] viewer exited with code " .. code .. " — check scripts/viewer_debug.log", vim.log.levels.ERROR)
          end)
        end
      end,
    })
    if not M._viewer_job or M._viewer_job <= 0 then
      return false, "failed to launch geometry viewer (jobstart returned " .. tostring(M._viewer_job) .. ")"
    end
    vim.notify("[geometry_preview] viewer started (job id=" .. M._viewer_job .. ")", vim.log.levels.INFO)
    -- Give viewer a moment to initialize before sending first payload
    vim.wait(500, function() return false end, 10)
  end

  local cmd_json = vim.json.encode({ cmd = "load", payload = all_payload }) .. "\n"
  local ok = pcall(vim.fn.chansend, M._viewer_job, cmd_json)
  if not ok then
    pcall(vim.fn.jobstop, M._viewer_job)
    M._viewer_job = nil
    return false, "viewer process is dead; retry with ,v"
  end
  vim.notify("[geometry_preview] payload sent to viewer", vim.log.levels.INFO)
  return true
end

return M
