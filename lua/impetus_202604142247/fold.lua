local M = {}

-- 【性能优化】禁用 fold 缓存重建
-- 原因：使用 foldmethod=manual，不需要自动 fold 计算
-- 打开 50 万行文件时，缓存重建耗时 1195+ ms
-- 禁用后，打开文件速度立即响应

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
  -- 【禁用】完全禁用 fold expression 缓存重建
  -- 原因：foldmethod=manual 时不需要自动计算
  -- 如果以后需要启用 fold expression，可以恢复这个实现
  return "="
end

function M.foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  local first = strip_number_prefix(line or ""):gsub("%s+$", "")
  local indent = first:match("^(%s*)") or ""
  local content = first:sub(#indent + 1)
  local hidden = math.max(0, vim.v.foldend - vim.v.foldstart)

  -- 【样式改进】新的折叠格式：+ Keyword....................................n lines
  -- "n lines" 始终靠右显示
  local line_count_str = string.format("%d lines", hidden)
  local prefix = indent .. "+ " .. content

  -- 获取窗口宽度
  local winwidth = vim.api.nvim_win_get_width(0)

  -- 计算可用宽度：窗口宽度 - 前缀宽度 - "n lines" 宽度 - 1个空格
  local prefix_width = vim.fn.strdisplaywidth(prefix)
  local suffix_width = vim.fn.strdisplaywidth(line_count_str) + 1  -- +1 为前面的空格
  local available_width = winwidth - prefix_width - suffix_width

  -- 计算点号数量（至少 1 个）
  local dot_count = math.max(1, available_width)
  local dots = string.rep(".", dot_count)

  return prefix .. dots .. " " .. line_count_str
end

return M
