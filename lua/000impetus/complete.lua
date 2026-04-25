local store = require("impetus.store")
local analysis = require("impetus.analysis")

local M = {}

local function pesc(s)
  if vim.pesc then
    return vim.pesc(s)
  end
  return (s:gsub("([^%w])", "%%%1"))
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_keyword(s)
  return (s:gsub("^%*", "")):lower()
end

local function normalize_param(s)
  return (s:gsub("^%[", ""):gsub("^%%", ""):gsub("%]$", "")):lower()
end

local function subseq_match(key, base)
  local j = 1
  local first_pos = nil
  local last_pos = nil
  for i = 1, #key do
    if key:sub(i, i) == base:sub(j, j) then
      if not first_pos then
        first_pos = i
      end
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
  vim.notify(string.format("[RANK_FILTER] start | candidates:%d | raw_base:'%s' | normalized_base:'%s'",
    #candidates, raw_base or "", base), vim.log.levels.WARN)
  if base == "" then
    local copied = vim.deepcopy(candidates)
    table.sort(copied)
    return copied
  end

  for _, c in ipairs(candidates) do
    local key = normalize_candidate(c)

    -- [IMPROVEMENT] tier 1: strict prefix match (BC at start)
    local start_pos = key:find(base, 1, true)
    if start_pos == 1 then
      out[#out + 1] = {
        item = c,
        tier = 1,
        span = #base,
        key = key,
      }
    elseif start_pos then
      -- [IMPROVEMENT] tier 2: contains match (BC in middle, e.g. *ABCNODE)
      out[#out + 1] = {
        item = c,
        tier = 2,
        span = #base,
        pos = start_pos,
        key = key,
      }
    else
      -- [IMPROVEMENT] tier 3+: fuzzy match, tiered by match compactness
      -- B*C (adjacent) -> tier=3, B**C -> tier=4, B***C -> tier=5
      local first_pos, span = subseq_match(key, base)
      if first_pos then
        -- tier by span (distance between B and C)
        -- smaller span (more compact match) -> smaller tier (higher priority)
        local distance = span - #base  -- number of chars between B and C
        local fuzzy_tier = 3 + math.floor(distance / 2)  -- +1 tier per 2 gaps
        fuzzy_tier = math.min(fuzzy_tier, 6)  -- cap max tier at 6

        out[#out + 1] = {
          item = c,
          tier = fuzzy_tier,
          span = span,
          key = key,
        }
      end
    end
  end

  -- [DIAG] pre-sort statistics
  local tier_count = {}
  for _, r in ipairs(out) do
    tier_count[r.tier] = (tier_count[r.tier] or 0) + 1
  end
  vim.notify(string.format("[FILTER] after filter | total:%d | tier_dist:%s",
    #out, vim.inspect(tier_count)), vim.log.levels.WARN)

  table.sort(out, function(a, b)
    if a.tier ~= b.tier then
      return a.tier < b.tier
    end
    if a.span ~= b.span then
      return a.span < b.span  -- smaller span first (more compact)
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

  -- [DEBUG] show sort result, verify changes take effect
  if #items > 0 and base ~= "" then
    local first_tier = out[1].tier or "?"
    local first_item = out[1].item or "?"
    local first_five = {}
    for i = 1, math.min(5, #items) do
      first_five[i] = items[i]
    end
    vim.notify(string.format("[RANK_RESULT] input:'%s' | 1st:%s(tier:%s) | top5:%s",
      base, first_item, first_tier, table.concat(first_five, " → ")), vim.log.levels.WARN)
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
  if left:match("^%s*%*[%w_%-]*$") then
    return true
  end
  return false
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
  local items = {}
  local db = store.get_db()

  -- [DIAG] input base value
  if base ~= "" then
    vim.notify(string.format("[COMPLETE] input base:'%s'", base), vim.log.levels.WARN)
  end

  if base:sub(1, 1) == "*" then
    local keywords = store.list_keywords()
    vim.notify(string.format("[COMPLETE] keyword complete | candidates:%d | base:'%s'",
      #keywords, base), vim.log.levels.WARN)
    return rank_filter(
      keywords,
      base:gsub("^%*", ""),
      normalize_keyword,
      function(s) return s:lower() end
    )
  end

  -- If cursor is on a keyword line, treat plain text like keyword completion too.
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

  -- Context-aware object id completion (e.g. BC typeid -> existing part ids).
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
  return items
end

function M.omnifunc(findstart, base)
  -- [DIAG] if this error appears, omnifunc was called
  if findstart ~= 1 then
    error(string.format("DEBUG: omnifunc called! base='%s'", base))
  end

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
  -- [DIAG] omnifunc was called
  vim.notify(string.format("[OMNIFUNC] called | findstart:%d | base:'%s'",
    findstart, base), vim.log.levels.WARN)
  local ok, result = pcall(M.complete, base)
  if not ok then
    vim.notify("impetus completion error: " .. tostring(result), vim.log.levels.ERROR)
    return {}
  end
  return result
end

return M
