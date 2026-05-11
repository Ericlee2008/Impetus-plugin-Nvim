local store = require("impetus.store")
local analysis = require("impetus.analysis")

local M = {}

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_keyword(s)
  return (s:gsub("^%*", "")):lower()
end

local function normalize_param(s)
  return (s:gsub("^%[", ""):gsub("^%%", ""):gsub("%]$", "")):lower()
end

local function subseq_match(key, base)
  local j = 1
  local first_pos, last_pos = nil, nil
  for i = 1, #key do
    if key:sub(i, i) == base:sub(j, j) then
      first_pos = first_pos or i
      last_pos = i
      j = j + 1
      if j > #base then
        return first_pos, last_pos - first_pos + 1
      end
    end
  end
  return nil, nil
end

local function rank_filter(candidates, raw_base, normalize_candidate, normalize_base)
  local out = {}
  local base = normalize_base(raw_base or "")
  if base == "" then
    local copied = vim.deepcopy(candidates)
    table.sort(copied)
    return copied
  end

  for _, c in ipairs(candidates) do
    local key = normalize_candidate(c)
    local start_pos = key:find(base, 1, true)
    if start_pos == 1 then
      out[#out + 1] = { item = c, tier = 1, span = #base, key = key }
    elseif start_pos then
      out[#out + 1] = { item = c, tier = 2, span = #base, pos = start_pos, key = key }
    else
      local first_pos, span = subseq_match(key, base)
      if first_pos then
        local distance = span - #base
        local fuzzy_tier = math.min(3 + math.floor(distance / 2), 6)
        out[#out + 1] = { item = c, tier = fuzzy_tier, span = span, key = key }
      end
    end
  end

  table.sort(out, function(a, b)
    if a.tier ~= b.tier then
      return a.tier < b.tier
    end
    if a.span ~= b.span then
      return a.span < b.span
    end
    if a.key ~= b.key then
      return a.key < b.key
    end
    return a.item < b.item
  end)

  local items = {}
  for _, r in ipairs(out) do
    items[#items + 1] = r.item
  end
  return items
end

local function get_current_keyword()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for i = row, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1] or ""
    local keyword = trim(line):match("^(%*[%u%d_%-]+)")
    if keyword then
      return keyword
    end
  end
  return nil
end

local function is_on_keyword_line()
  local line = vim.api.nvim_get_current_line()
  local cursor_col = vim.fn.col(".") - 1
  local left = line:sub(1, math.max(cursor_col, 0))
  return left:match("^%s*%*[%w_%-]*$") ~= nil
end

local function collect_parameters_from_buffer()
  local out = {}
  local seen = {}
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(lines) do
    local name = line:match("^%s*%%?([%a_][%w_]*)%s*=")
    if name and not seen[name] then
      seen[name] = true
      out[#out + 1] = "%" .. name
    end
  end
  table.sort(out)
  return out
end

function M.complete(base)
  base = base or ""
  local db = store.get_db()

  if base:sub(1, 1) == "*" then
    return rank_filter(
      store.list_keywords(),
      base:gsub("^%*", ""),
      normalize_keyword,
      function(s) return s:lower() end
    )
  end

  if is_on_keyword_line() then
    return rank_filter(
      store.list_keywords(),
      base,
      normalize_keyword,
      function(s) return s:lower() end
    )
  end

  if base:sub(1, 1) == "%" or base:sub(1, 2) == "[%" then
    return rank_filter(
      collect_parameters_from_buffer(),
      base:gsub("^%[", ""):gsub("^%%", ""):gsub("%]$", ""),
      normalize_param,
      function(s) return s:lower() end
    )
  end

  local keyword = get_current_keyword()
  local entry = keyword and db[keyword] or nil
  local ctx = analysis.current_context(0)

  if ctx and ctx.param_name then
    local object_ids = analysis.suggest_object_values(0, ctx, base)
    if #object_ids > 0 then
      return object_ids
    end
  end

  if entry and entry.params then
    return rank_filter(
      entry.params,
      base,
      function(s) return s:lower() end,
      function(s) return s:lower() end
    )
  end

  return {}
end

function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col(".") - 1
    while col > 0 do
      local ch = line:sub(col, col)
      if ch:match("[%w_%%%*%[%-]") then
        col = col - 1
      else
        break
      end
    end
    return col
  end

  local ok, result = pcall(M.complete, base)
  if not ok then
    vim.notify("impetus completion error: " .. tostring(result), vim.log.levels.ERROR)
    return {}
  end
  return result
end

return M
