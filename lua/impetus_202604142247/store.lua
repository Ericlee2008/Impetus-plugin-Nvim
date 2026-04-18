local parser = require("impetus.parser")

local M = {}

local db = {}
local source_path = nil

local function default_cache_path()
  local data_path = vim.fn.stdpath("data")
  if data_path and data_path ~= "" and vim.fn.isdirectory(data_path) == 1 then
    return data_path .. "/impetus-keywords.json"
  end
  return vim.fn.getcwd() .. "/.impetus-keywords.json"
end

local function normalize_path(path)
  if not path or path == "" then
    return nil
  end
  return vim.fn.fnamemodify(path, ":p")
end

function M.set_path(path)
  source_path = normalize_path(path)
end

function M.get_path()
  return source_path
end

function M.get_db()
  return db
end

function M.get_keyword(name)
  return db[name]
end

function M.list_keywords()
  local out = {}
  for k, _ in pairs(db) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

function M.load_from_file(path)
  local absolute = normalize_path(path)
  if not absolute or vim.fn.filereadable(absolute) == 0 then
    return false, "help file not found: " .. tostring(path)
  end
  db = parser.parse_file(absolute)
  source_path = absolute
  return true
end

function M.save_cache(path)
  local target = normalize_path(path) or default_cache_path()
  local encoded = vim.json.encode(db)
  local ok = pcall(vim.fn.writefile, { encoded }, target)
  if ok then
    return target
  end
  local fallback = vim.fn.getcwd() .. "/.impetus-keywords.json"
  vim.fn.writefile({ encoded }, fallback)
  return fallback
end

function M.load_cache(path)
  local target = normalize_path(path) or default_cache_path()
  if vim.fn.filereadable(target) == 0 then
    return false, "cache file not found: " .. target
  end
  local content = table.concat(vim.fn.readfile(target), "\n")
  db = vim.json.decode(content)
  return true
end

return M
