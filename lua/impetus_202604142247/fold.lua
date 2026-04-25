local M = {}

-- [Performance] Disable fold cache rebuild
-- Reason: using foldmethod=manual, no automatic fold calculation needed
-- When opening 500k-line files, cache rebuild takes 1195+ ms
-- After disabling, file open speed is immediately responsive

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_number_prefix(line)
  return (line:gsub("^%s*%d+%.%s*", ""))
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
  -- [Disabled] Completely disable fold expression cache rebuild
  -- Reason: no automatic calculation needed when foldmethod=manual
  -- If fold expression is needed later, this implementation can be restored
  return "="
end

function M.foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  local first = strip_number_prefix(line or ""):gsub("%s+$", "")
  local indent = first:match("^(%s*)") or ""
  local content = first:sub(#indent + 1)
  local hidden = math.max(0, vim.v.foldend - vim.v.foldstart)

  -- [Style] New fold format: + Keyword....................................n lines
  -- "n lines" always aligned to the right
  local line_count_str = string.format("%d lines", hidden)
  local prefix = indent .. "+ " .. content

  -- Get window width
  local winwidth = vim.api.nvim_win_get_width(0)

  -- Calculate available width: window width - prefix width - "n lines" width - 1 space
  local prefix_width = vim.fn.strdisplaywidth(prefix)
  local suffix_width = vim.fn.strdisplaywidth(line_count_str) + 1  -- +1 for the leading space
  local available_width = winwidth - prefix_width - suffix_width

  -- Calculate dot count (at least 1)
  local dot_count = math.max(1, available_width)
  local dots = string.rep(".", dot_count)

  return prefix .. dots .. " " .. line_count_str
end

return M
