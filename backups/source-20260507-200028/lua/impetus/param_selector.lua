-- param_selector.lua
-- Parameter value selector popup for quick option insertion

local M = {}

local popup_state = {
  win_id = nil,
  buf_id = nil,
  options = {},
  selected_idx = 1,
}

-- Forward declarations
local update_popup_display
local confirm_selection

local function close_popup()
  if popup_state.win_id and vim.api.nvim_win_is_valid(popup_state.win_id) then
    vim.api.nvim_win_close(popup_state.win_id, true)
  end
  if popup_state.buf_id and vim.api.nvim_buf_is_valid(popup_state.buf_id) then
    vim.api.nvim_buf_delete(popup_state.buf_id, { force = true })
  end
  popup_state.win_id = nil
  popup_state.buf_id = nil
end

local function extract_options_from_description(desc)
  if not desc or desc == "" then
    return nil
  end

  -- Extract options from format: "... [options: N, NS, P, PS, ...]"
  local options_str = desc:match("%[options:%s*([^%]]+)%]")
  if not options_str then
    return nil
  end

  local options = {}
  for opt in options_str:gmatch("[^,%s]+") do
    if opt ~= "" then
      table.insert(options, opt)
    end
  end

  return #options > 0 and options or nil
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_csv(line)
  local out = {}
  local col_start = 0
  for part in line:gmatch("[^,]+") do
    local trimmed = trim(part)
    if trimmed ~= "" or part ~= "" then
      table.insert(out, {
        value = trimmed,
        start_col = col_start,
        end_col = col_start + #part - 1,
      })
    end
    col_start = col_start + #part + 1
  end
  return out
end

local function get_cursor_context()
  local buf = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1 -- convert to 0-indexed

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Find the keyword this row belongs to
  local keyword_row = nil
  for i = row, 0, -1 do
    local line = lines[i + 1] or ""
    if line:match("^%*[%u%d_%-]+") then
      keyword_row = i
      break
    end
  end

  if not keyword_row then
    return nil
  end

  -- Extract keyword name
  local keyword_line = lines[keyword_row + 1] or ""
  local keyword = keyword_line:match("^(%*[%u%d_%-]+)")
  if not keyword then
    return nil
  end

  -- Get the db
  local ok, db = pcall(require("impetus.store").get_db)
  if not ok or not db then
    return nil
  end

  local kw_entry = db[keyword]
  if not kw_entry then
    return nil
  end

  -- Parse parameter columns from the current row
  local current_line = lines[row + 1] or ""
  local params_in_row = split_csv(current_line)

  -- Find which parameter contains the cursor
  local cursor_param = nil
  local param_idx_in_row = nil
  for idx, p in ipairs(params_in_row) do
    if col >= p.start_col and col <= p.end_col then
      cursor_param = p
      param_idx_in_row = idx
      break
    end
  end

  if not cursor_param or not param_idx_in_row then
    return nil
  end

  -- Calculate the global parameter index by counting parameters in previous rows
  local param_idx = param_idx_in_row

  -- Count parameters in all rows before the current row
  for check_row = keyword_row + 1, row - 1 do
    local check_line = lines[check_row + 1] or ""
    -- Skip empty lines, Optional title, and separators
    if check_line ~= "" and check_line ~= '"Optional title"' and not check_line:match("^%-%-%-%-") and not check_line:match("^%*") then
      local check_params = split_csv(check_line)
      param_idx = param_idx + #check_params
    end
  end

  if param_idx > #kw_entry.params or param_idx < 1 then
    return nil
  end

  local param_name = kw_entry.params[param_idx]
  if not param_name or param_name == "" then
    return nil
  end

  return {
    keyword = keyword,
    param_name = param_name,
    param_idx = param_idx,
    cursor_param = cursor_param,
    row = row,
    col = col,
  }
end

local function show_popup(options)
  close_popup()

  if not options or #options == 0 then
    vim.notify("No options available for this parameter", vim.log.levels.INFO)
    return
  end

  popup_state.options = options
  popup_state.selected_idx = 1

  -- Create buffer
  popup_state.buf_id = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(popup_state.buf_id, "modifiable", true)

  -- Set content with highlighting
  local lines = {}
  for idx, opt in ipairs(options) do
    if idx == popup_state.selected_idx then
      table.insert(lines, "> " .. opt)
    else
      table.insert(lines, "  " .. opt)
    end
  end
  vim.api.nvim_buf_set_lines(popup_state.buf_id, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(popup_state.buf_id, "modifiable", false)

  -- Calculate window size
  local max_width = 0
  for _, opt in ipairs(options) do
    max_width = math.max(max_width, #opt + 2)
  end
  local width = math.min(math.max(max_width, 20), 50)
  local height = math.min(#options + 2, 20)

  -- Create floating window
  local opts = {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  }

  popup_state.win_id = vim.api.nvim_open_win(popup_state.buf_id, true, opts)
  vim.api.nvim_win_set_option(popup_state.win_id, "wrap", false)

  -- Set up keybindings for the popup
  local popup_buf = popup_state.buf_id

  vim.keymap.set("n", "j", function()
    if popup_state.selected_idx < #popup_state.options then
      popup_state.selected_idx = popup_state.selected_idx + 1
      update_popup_display()
    end
  end, { buffer = popup_buf, noremap = true, silent = true })

  vim.keymap.set("n", "k", function()
    if popup_state.selected_idx > 1 then
      popup_state.selected_idx = popup_state.selected_idx - 1
      update_popup_display()
    end
  end, { buffer = popup_buf, noremap = true, silent = true })

  vim.keymap.set("n", "<Space>", function()
    local selected_opt = popup_state.options[popup_state.selected_idx]
    if selected_opt then
      confirm_selection(selected_opt)
    end
  end, { buffer = popup_buf, noremap = true, silent = true })

  vim.keymap.set("n", "<Esc>", close_popup, { buffer = popup_buf, noremap = true, silent = true })
end

update_popup_display = function()
  if not popup_state.buf_id or not vim.api.nvim_buf_is_valid(popup_state.buf_id) then
    return
  end

  local lines = {}
  for idx, opt in ipairs(popup_state.options) do
    if idx == popup_state.selected_idx then
      table.insert(lines, "> " .. opt)
    else
      table.insert(lines, "  " .. opt)
    end
  end
  vim.api.nvim_buf_set_lines(popup_state.buf_id, 0, -1, false, lines)
end

confirm_selection = function(selected_opt)
  -- Get the main window (the one before we opened the popup)
  -- Find a window that's not the popup window
  local target_win = nil
  for _, win_id in ipairs(vim.api.nvim_list_wins()) do
    if win_id ~= popup_state.win_id then
      target_win = win_id
      break
    end
  end

  if not target_win then
    close_popup()
    return
  end

  local buf = vim.api.nvim_win_get_buf(target_win)
  local cursor_pos = vim.api.nvim_win_get_cursor(target_win)
  local row = cursor_pos[1] - 1
  local col = cursor_pos[2]

  local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
  if not lines or #lines == 0 then
    close_popup()
    return
  end

  local line = lines[1]

  -- Re-extract context to get accurate column positions
  local current_line = line
  local params_in_row = split_csv(current_line)

  local cursor_param = nil
  for idx, p in ipairs(params_in_row) do
    if col >= p.start_col and col <= p.end_col then
      cursor_param = p
      break
    end
  end

  if not cursor_param then
    close_popup()
    return
  end

  -- Replace the parameter value at cursor position
  local before = line:sub(1, cursor_param.start_col)
  local after = line:sub(cursor_param.end_col + 1)
  local new_line = before .. selected_opt .. after

  vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { new_line })

  close_popup()

  -- Restore focus to the target window
  vim.api.nvim_set_current_win(target_win)
end

function M.show_param_selector()
  local context = get_cursor_context()
  if not context then
    vim.notify("Not on a valid parameter position", vim.log.levels.WARN)
    return
  end

  local ok, db = pcall(require("impetus.store").get_db)
  if not ok or not db then
    vim.notify("Keyword database not loaded", vim.log.levels.WARN)
    return
  end

  local kw_entry = db[context.keyword]
  if not kw_entry then
    vim.notify("Keyword not found in database", vim.log.levels.WARN)
    return
  end

  local param_detail = kw_entry.details and kw_entry.details[context.param_idx]
  if not param_detail or not param_detail.description then
    vim.notify("No description available for this parameter", vim.log.levels.INFO)
    return
  end

  local options = extract_options_from_description(param_detail.description)
  if not options then
    vim.notify("No predefined options for this parameter", vim.log.levels.INFO)
    return
  end

  show_popup(options)
end

return M
