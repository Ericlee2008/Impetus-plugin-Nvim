local complete = require("impetus.complete")
local template = require("impetus.template")

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

local function is_keyword_context(line, cur_col)
  local left = line:sub(1, math.max(cur_col, 0))
  return left:match("^%s*%*[%w_%-]*$") ~= nil
end

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
  return { "*", "%", "[", "," }
end

function Source:get_completions(context, resolve)
  local line = context.line or vim.api.nvim_get_current_line()
  local cursor = context.cursor or { vim.api.nvim_win_get_cursor(0)[1], vim.api.nvim_win_get_cursor(0)[2] }
  local cur_col = cursor[2]
  local start_col = find_start_col(line, cur_col)
  local base = line:sub(start_col + 1, cur_col)
  local keyword_ctx = is_keyword_context(line, cur_col)
  local is_comma_trigger = context.trigger and context.trigger.kind == 2 and context.trigger.character == ","

  if not keyword_ctx and not is_comma_trigger and #base < (self.opts.min_keyword_length or 1) then
    resolve({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
    return
  end

  local words = complete.complete(base)
  if keyword_ctx then
    local query = base
    if query:sub(1, 1) ~= "*" then
      query = "*" .. query
    end
    words = complete.complete(query)
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
      score = 1000 - idx,
      kind = kind,
      insertTextFormat = insert_format,
      data = { impetus_template = is_template },
      textEdit = {
        range = range,
        newText = new_text,
      },
    }
  end

  resolve({
    is_incomplete_forward = true,
    is_incomplete_backward = true,
    items = items,
  })
end

local function jump_to_next_field()
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  -- Search from current position (col0+1 in 1-based handles cursor at "X" or at the trailing comma)
  local next_comma = line:find(",", col0 + 1, true)
  if next_comma then
    local new_col0 = next_comma  -- 0-based position right after the comma
    while new_col0 < #line and line:sub(new_col0 + 1, new_col0 + 1):match("%s") do
      new_col0 = new_col0 + 1
    end
    vim.api.nvim_win_set_cursor(0, { row, new_col0 })
  end
  vim.cmd("startinsert")
end

function Source:execute(_, _, callback, default_implementation)
  default_implementation()
  vim.schedule(jump_to_next_field)
  callback()
end

return Source
