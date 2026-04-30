local config = require("impetus.config")

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
  if normalized == "" then
    return true
  end
  if normalized:sub(1, 1) == "#" or normalized:sub(1, 1) == "$" then
    return true
  end
  if normalized:sub(1, 1) == "~" then
    return true
  end
  if normalized:match("^%-+$") then
    return true
  end
  if normalized == "Variable         Description" then
    return true
  end
  if normalized == '"Optional title"' or normalized:match('^".*"$') then
    return true
  end
  return false
end

local function extract_numbers(line)
  local out = {}
  for token in (line or ""):gmatch("[^,%s]+") do
    local n = token:match("^[-+]?%d*%.?%d+[eE][-+]?%d+$")
    if not n then
      n = token:match("^[-+]?%d*%.?%d+$")
    end
    if n then
      out[#out + 1] = tonumber(n)
    end
  end
  return out
end

local function flatten_points(lines)
  local points = {}
  local scalars = {}
  local raw_numbers = {}
  for _, line in ipairs(lines or {}) do
    if not is_meta_line(line) then
      local nums = extract_numbers(line)
      for _, n in ipairs(nums) do
        raw_numbers[#raw_numbers + 1] = n
      end
      if #nums == 1 then
        scalars[#scalars + 1] = nums[1]
      end
      local i = 1
      while i + 2 <= #nums do
        points[#points + 1] = { nums[i], nums[i + 1], nums[i + 2] }
        i = i + 3
      end
    end
  end
  return points, scalars, raw_numbers
end

local function find_last_value_line(lines)
  for i = #lines, 1, -1 do
    local line = lines[i] or ""
    if not is_meta_line(line) then
      local nums = extract_numbers(line)
      if #nums > 0 then
        return nums, line
      end
    end
  end
  return nil, nil
end

local function find_first_value_line(lines)
  for i = 1, #lines do
    local line = lines[i] or ""
    if not is_meta_line(line) then
      local nums = extract_numbers(line)
      if #nums > 0 then
        return nums, line
      end
    end
  end
  return nil, nil
end

local function shape_from_keyword(keyword, lines)
  local k = (keyword or ""):lower()
  if k:find("sphere", 1, true) then
    return "sphere"
  end
  if k:find("cyl", 1, true) then
    return "cylinder"
  end
  if k:find("box", 1, true) then
    return "box"
  end
  local first = trim(strip_number_prefix(lines[1] or "")):lower()
  if first == "box" or first == "sphere" or first == "cylinder" then
    return first
  end
  return nil
end

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

  local shape = shape_from_keyword(block.keyword, block_lines)
  if not shape then
    return nil, "could not infer geometry shape from '" .. block.keyword .. "'"
  end

  local points, scalars, raw_numbers = flatten_points(block_lines)
  local payload_splits = nil
  if (block.keyword or ""):upper() == "*COMPONENT_BOX" then
    local first_nums = find_first_value_line(block_lines)
    if not first_nums or #first_nums < 5 then
      return nil, "*COMPONENT_BOX needs at least 5 numeric values on the first data line"
    end
    local nums = find_last_value_line(block_lines)
    if not nums or #nums < 6 then
      return nil, "*COMPONENT_BOX needs at least 6 numeric values on the last data line"
    end
    local split_x = math.max(1, math.floor(tonumber(first_nums[3]) or 1))
    local split_y = math.max(1, math.floor(tonumber(first_nums[4]) or 1))
    local split_z = math.max(1, math.floor(tonumber(first_nums[5]) or 1))
    points = {
      { nums[1], nums[2], nums[3] },
      { nums[4], nums[5], nums[6] },
    }
    scalars = {}
    raw_numbers = { nums[1], nums[2], nums[3], nums[4], nums[5], nums[6] }
    payload_splits = { split_x, split_y, split_z }
  end
  local payload = {
    keyword = block.keyword,
    shape = shape,
    file = vim.api.nvim_buf_get_name(bufnr),
    cursor_row = row,
    block = {
      start_row = block.start_row,
      end_row = block.end_row,
      lines = block_lines,
    },
    points = points,
    scalars = scalars,
    numbers = raw_numbers,
    splits = payload_splits,
  }
  return payload
end

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

  local python = opts.python_exe or "python"
  local args = opts.python_args or {}
  local cmd = { python }
  for _, a in ipairs(args) do
    cmd[#cmd + 1] = a
  end
  cmd[#cmd + 1] = script
  cmd[#cmd + 1] = payload_path

  local ret = vim.fn.jobstart(cmd, {
    detach = true,
  })
  if ret <= 0 then
    return false, "failed to launch geometry viewer"
  end
  return true
end

return M
