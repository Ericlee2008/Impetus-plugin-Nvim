local M = {}
local schema = require("impetus.schema")

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_bom(s)
  return (s:gsub("^\239\187\191", ""))
end

local function split_csv(line)
  local out = {}
  for part in line:gmatch("[^,]+") do
    local v = trim(part)
    if v ~= "" then
      table.insert(out, v)
    end
  end
  return out
end

local function strip_number_prefix(line)
  line = strip_bom(line)
  return (line:gsub("^%s*%d+%.%s*", ""))
end

local function is_separator(line)
  local normalized = strip_number_prefix(line)
  return normalized:find("%-%-%-%-%-") ~= nil
end

local function is_keyword_line(line)
  local normalized = strip_number_prefix(line)
  return normalized:match("^%*[%u%d_%-]+")
end

local function is_non_data_line(line)
  if line == "" then
    return true
  end
  if line:sub(1, 1) == "#" or line:sub(1, 1) == "$" then
    return true
  end
  if line:match('^".*"$') then
    return true
  end
  if line == "Variable         Description" then
    return true
  end
  return false
end

local function parse_param_lines(lines, start_i, end_i)
  local params = {}
  local signature_rows = {}
  for i = start_i, end_i do
    local raw = strip_number_prefix(lines[i])
    local line = trim(raw)
    if not is_non_data_line(line) then
      local row = split_csv(line)
      if #row > 0 then
        table.insert(signature_rows, row)
        for _, p in ipairs(row) do
          table.insert(params, p)
        end
      end
    end
  end
  return params, signature_rows
end

local function parse_desc_lines(lines, start_i, end_i)
  local descriptions = {}
  local last_vars = {}
  for i = start_i, end_i do
    local raw = strip_number_prefix(lines[i])
    local line = trim(raw)
    if line ~= "" and line:sub(1, 1) ~= "#" and line:sub(1, 1) ~= "$" then
      local left, right = line:match("^([^:]+)%s*:%s*(.+)$")
      if left and right then
        local key = trim(left):lower()
        if key ~= "options" and key ~= "default" then
          last_vars = {}
          for _, var_name in ipairs(split_csv(left)) do
            local v = trim(var_name)
            if v ~= "" then
              descriptions[v] = right
              table.insert(last_vars, v)
            end
          end
        elseif #last_vars > 0 then
          for _, v in ipairs(last_vars) do
            descriptions[v] = descriptions[v] .. " [" .. key .. ": " .. right .. "]"
          end
        end
      elseif #last_vars > 0 then
        for _, v in ipairs(last_vars) do
          descriptions[v] = descriptions[v] .. " " .. line
        end
      end
    end
  end
  return descriptions
end

local function parse_block(lines, start_i, end_i)
  local header = trim(strip_number_prefix(lines[start_i]))
  local keyword = header:match("^(%*[%u%d_%-]+)")
  if not keyword then
    return nil
  end

  local separator_i
  for i = start_i + 1, end_i do
    if is_separator(lines[i]) then
      separator_i = i
      break
    end
  end

  local params = {}
  local signature_rows = {}
  local descriptions = {}
  local has_optional_title = false
  if separator_i then
    for i = start_i + 1, separator_i - 1 do
      local line = trim(strip_number_prefix(lines[i]))
      if line == '"Optional title"' then
        has_optional_title = true
        break
      end
    end
    params, signature_rows = parse_param_lines(lines, start_i + 1, separator_i - 1)
    descriptions = parse_desc_lines(lines, separator_i + 1, end_i)
  else
    for i = start_i + 1, end_i do
      local line = trim(strip_number_prefix(lines[i]))
      if line == '"Optional title"' then
        has_optional_title = true
        break
      end
    end
    params, signature_rows = parse_param_lines(lines, start_i + 1, end_i)
  end

  local details = {}
  for _, p in ipairs(params) do
    details[#details + 1] = {
      name = p,
      description = descriptions[p] or "",
    }
  end

  local help_lines = {}
  for i = start_i, end_i do
    local raw = lines[i] or ""
    if i == start_i then
      raw = strip_bom(raw)
    end
    help_lines[#help_lines + 1] = raw
  end

  return {
    keyword = keyword,
    params = params,
    signature_rows = signature_rows,
    descriptions = descriptions,
    details = details,
    has_optional_title = has_optional_title,
    help_lines = help_lines,
    meta = schema.keyword_meta(keyword, {
      signature_rows = signature_rows,
      has_optional_title = has_optional_title,
      descriptions = descriptions,
    }),
  }
end

function M.parse_lines(lines)
  local blocks = {}
  local i = 1
  while i <= #lines do
    if is_keyword_line(lines[i]) then
      local start_i = i
      i = i + 1
      while i <= #lines and not is_keyword_line(lines[i]) do
        i = i + 1
      end
      local block = parse_block(lines, start_i, i - 1)
      if block then
        if not blocks[block.keyword] then
          blocks[block.keyword] = block
        end
      end
    else
      i = i + 1
    end
  end
  return blocks
end

function M.parse_file(path)
  local lines = vim.fn.readfile(path)
  return M.parse_lines(lines)
end

return M
