local complete = require("impetus.complete")
local template = require("impetus.template")
local store = require("impetus.store")

-- 【诊断】确认模块被加载
vim.notify("[blink_source] 模块已加载", vim.log.levels.WARN)

local Source = {}

local function find_start_col(line, cur_col)
  local col = cur_col
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

local function normalize_keyword(s)
  return (s:gsub("^%*", "")):lower()
end

local function is_keyword_context(line, cur_col)
  local left = line:sub(1, math.max(cur_col, 0))
  return left:match("^%s*%*[%w_%-]*$") ~= nil
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

local function rank_keywords_by_input(base)
  -- 【关键诊断】确认这个函数是否被调用
  local log_path = vim.fn.stdpath("cache") .. "/impetus_blink.log"
  local f = io.open(log_path, "a")
  if f then
    f:write(string.format(">>> RANK_KEYWORDS_BY_INPUT 被调用了!!! base='%s'\n", base))
    f:close()
  end

  local kws = store.list_keywords()
  local needle = normalize_keyword(base or "")
  if needle == "" then
    table.sort(kws)
    return kws
  end

  local ranked = {}

  for _, kw in ipairs(kws) do
    local key = normalize_keyword(kw)

    -- 【改进】Tier 1: 严格前缀匹配（BC开头）
    local pos = key:find(needle, 1, true)
    if pos == 1 then
      ranked[#ranked + 1] = { item = kw, tier = 1, span = #needle, key = key }
    elseif pos then
      -- 【改进】Tier 2: 包含匹配（BC在中间）
      ranked[#ranked + 1] = { item = kw, tier = 2, span = #needle, pos = pos, key = key }
    else
      -- 【改进】Tier 3+: 模糊匹配，根据匹配的紧凑程度分tier
      local first_pos, s_span = subseq_match(key, needle)
      if first_pos then
        -- 根据span（B和C之间的距离）来分tier
        -- span越小（匹配越紧凑）tier越小（优先级越高）
        local distance = s_span - #needle  -- B和C之间相隔的字符数
        local fuzzy_tier = 3 + math.floor(distance / 2)  -- 每2个间隔增加1个tier
        fuzzy_tier = math.min(fuzzy_tier, 6)  -- 限制最高tier为6

        ranked[#ranked + 1] = { item = kw, tier = fuzzy_tier, span = s_span, key = key }
      end
    end
  end

  -- 【诊断】写入排序前的tier分布
  local tier_count = {}
  for _, r in ipairs(ranked) do
    tier_count[r.tier] = (tier_count[r.tier] or 0) + 1
  end
  local log_path = vim.fn.stdpath("cache") .. "/impetus_blink.log"
  local f = io.open(log_path, "a")
  if f then
    f:write(string.format("  rank_keywords_by_input: input='%s', candidates=%d, tier_dist=%s\n",
      needle, #ranked, vim.inspect(tier_count)))
    f:close()
  end

  -- 排序：按tier、span、key、item
  table.sort(ranked, function(a, b)
    if a.tier ~= b.tier then return a.tier < b.tier end
    if a.span ~= b.span then return a.span < b.span end  -- 匹配跨度小的优先
    if a.key ~= b.key then return a.key < b.key end
    return a.item < b.item
  end)

  local out = {}
  for _, r in ipairs(ranked) do
    out[#out + 1] = r.item
  end

  -- 【诊断】写入排序后的结果
  if #out > 0 then
    local first_five = {}
    for i = 1, math.min(5, #out) do
      first_five[i] = out[i]
    end
    local log_path = vim.fn.stdpath("cache") .. "/impetus_blink.log"
    local f = io.open(log_path, "a")
    if f then
      f:write(string.format("  result: top5=[%s]\n", table.concat(first_five, " → ")))
      f:close()
    end
  end

  return out
end

---@param _ table|nil
---@param config table|nil
---@return table
function Source.new(_, config)
  local self = setmetatable({}, { __index = Source })
  self.opts = vim.tbl_deep_extend("force", {
    filetypes = { "impetus", "kwt" },
    min_keyword_length = 1,
  }, (config and config.opts) or {})
  return self
end

function Source:enabled()
  local ft = vim.bo.filetype
  return vim.tbl_contains(self.opts.filetypes, ft)
end

function Source:get_trigger_characters()
  return { "*", "%", "[" }
end

function Source:get_completions(context, resolve)
  local line = context.line or vim.api.nvim_get_current_line()
  local cursor = context.cursor or { vim.api.nvim_win_get_cursor(0)[1], vim.api.nvim_win_get_cursor(0)[2] }
  local cur_col = cursor[2]

  -- 【详细诊断】记录 context 的原始信息
  local log_path = vim.fn.stdpath("cache") .. "/impetus_blink.log"
  local f = io.open(log_path, "a")
  if f then
    f:write(string.format("[%s] === NEW CALL ===\n", os.date("%H:%M:%S")))
    f:write(string.format("  context.line='%s' (len=%d)\n", context.line or "nil", context.line and #context.line or 0))
    f:write(string.format("  vim.api.nvim_get_current_line()='%s'\n", vim.api.nvim_get_current_line()))
    f:write(string.format("  context.cursor=%s\n", vim.inspect(context.cursor)))
    f:write(string.format("  vim.api.nvim_win_get_cursor(0)=%s\n", vim.inspect(vim.api.nvim_win_get_cursor(0))))
    f:close()
  end

  local start_col = find_start_col(line, cur_col)
  local base = line:sub(start_col + 1, cur_col)

  -- 【诊断】写入文件日志
  local f2 = io.open(log_path, "a")
  if f2 then
    f2:write(string.format("  处理后: line='%s', base='%s', cur_col=%d, start_col=%d\n",
      line, base, cur_col, start_col))
    f2:close()
  end

  if #base < (self.opts.min_keyword_length or 1) then
    resolve({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
    return
  end

  local words
  local keyword_ctx = is_keyword_context(line, cur_col)

  -- 【诊断】记录上下文判断
  local f2 = io.open(log_path, "a")
  if f2 then
    f2:write(string.format("  keyword_ctx=%s, left='%s'\n", keyword_ctx and "TRUE" or "FALSE", line:sub(1, cur_col)))
    f2:close()
  end

  if keyword_ctx then
    words = rank_keywords_by_input(base)
  else
    words = complete.complete(base)
  end
  local range = {
    ["start"] = { line = cursor[1] - 1, character = start_col },
    ["end"] = { line = cursor[1] - 1, character = cur_col },
  }

  local items = {}
  for idx, w in ipairs(words) do
    local kind = vim.lsp.protocol.CompletionItemKind.Text
    local new_text = w
    local insert_format = vim.lsp.protocol.InsertTextFormat.PlainText
    local is_template = false
    if w:sub(1, 1) == "*" then
      kind = vim.lsp.protocol.CompletionItemKind.Snippet
      new_text = template.keyword_block_snippet(w)
      insert_format = vim.lsp.protocol.InsertTextFormat.Snippet
      is_template = true
    elseif w:sub(1, 1) == "%" then
      kind = vim.lsp.protocol.CompletionItemKind.Variable
    end
    items[#items + 1] = {
      label = w,
      sortText = string.format("%06d_%s", idx, w:lower()),
      -- 【改进】添加 score 信息，高 score 表示更优先
      -- 这样即使 blink.cmp 考虑 score，也会遵循我们的优先级
      score = 1000 - idx,
      kind = kind,
      insertTextFormat = insert_format,
      data = {
        impetus_template = is_template,
      },
      textEdit = {
        range = range,
        newText = new_text,
      },
    }
  end

  -- 【关键改进】设置两个标志为 true
  -- is_incomplete_forward = true: 用户输入更多字符时重新调用
  -- is_incomplete_backward = true: 用户删除字符时也重新调用
  -- 这样补全列表会动态随着用户输入实时变化
  resolve({ is_incomplete_forward = true, is_incomplete_backward = true, items = items })
end

function Source:execute(_, item, callback, default_implementation)
  default_implementation()
  vim.schedule(function()
    vim.cmd("startinsert")
  end)
  callback()
end

return Source
