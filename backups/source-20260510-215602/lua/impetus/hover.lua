local store = require("impetus.store")

local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_word(word)
  local w = word:gsub("[%[%],]", "")
  if w:match("^%%") then
    return w:sub(2)
  end
  return w
end

local function get_keyword_under_cursor()
  local line = trim(vim.api.nvim_get_current_line())
  return line:match("^(%*[%u%d_%-]+)")
end

local function find_param_entry(entry, param_name)
  if not entry or not entry.details then
    return nil
  end
  for _, d in ipairs(entry.details) do
    if normalize_word(d.name) == param_name then
      return d
    end
  end
  return nil
end

function M.show_under_cursor()
  local keyword = get_keyword_under_cursor()
  if keyword then
    local entry = store.get_keyword(keyword)
    if not entry then
      vim.notify("No docs for " .. keyword, vim.log.levels.WARN)
      return
    end
    local lines = { keyword }
    if entry.params and #entry.params > 0 then
      lines[#lines + 1] = "Params: " .. table.concat(entry.params, ", ")
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Impetus" })
    return
  end

  local cword = vim.fn.expand("<cword>")
  local param = normalize_word(cword)
  if param == "" then
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  for i = row, 1, -1 do
    local line = trim(vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1] or "")
    local kw = line:match("^(%*[%u%d_%-]+)")
    if kw then
      local entry = store.get_keyword(kw)
      local detail = find_param_entry(entry, param)
      if detail then
        local msg = kw .. "\n" .. detail.name .. ": " .. (detail.description ~= "" and detail.description or "No description")
        vim.notify(msg, vim.log.levels.INFO, { title = "Impetus" })
        return
      end
      break
    end
  end

  vim.notify("No docs for '" .. cword .. "'", vim.log.levels.WARN, { title = "Impetus" })
end

return M
