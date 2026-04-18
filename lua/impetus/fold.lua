local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_number_prefix(line)
  return (line:gsub("^%s*%d+%.%s*", ""))
end

local function indent_level(lnum)
  local indent = tonumber(vim.fn.indent(lnum)) or 0
  -- Use 2 spaces as one nesting level.
  return math.floor(indent / 2) + 1
end

local function classify(line)
  local normalized = trim(strip_number_prefix(line or ""))
  if normalized == "" then
    return "blank"
  end
  if normalized:match("^%*[%w_%-]+") then
    return "keyword"
  end
  if normalized:match("^~if%f[%A]") or normalized:match("^~repeat%f[%A]") or normalized:match("^~convert_from_") then
    return "dir_start"
  end
  if normalized:match("^~else_if%f[%A]") or normalized:match("^~else%f[%A]") then
    return "dir_mid"
  end
  if normalized:match("^~end_if%f[%A]") or normalized:match("^~end_repeat%f[%A]") or normalized:match("^~end_convert%f[%A]") then
    return "dir_end"
  end
  return "other"
end

function M.foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  local kind = classify(line)
  local lvl = indent_level(lnum)

  if kind == "keyword" then
    return ">" .. tostring(lvl)
  end
  if kind == "dir_start" then
    return ">" .. tostring(lvl)
  end
  if kind == "dir_mid" then
    return ">" .. tostring(lvl)
  end
  if kind == "dir_end" then
    -- Close the fold *including* this end-directive line.
    return "<" .. tostring(math.max(1, lvl))
  end
  return "="
end

function M.foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  local first = strip_number_prefix(line or ""):gsub("%s+$", "")
  local indent = first:match("^(%s*)") or ""
  local content = first:sub(#indent + 1)
  local hidden = math.max(0, vim.v.foldend - vim.v.foldstart)
  if hidden <= 0 then
    return indent .. "+ " .. content
  end
  local suffix = string.format(" (%d lines)", hidden)
  return indent .. "+ " .. content .. suffix
end

return M
