local config = require("impetus.config")
local store = require("impetus.store")
local commands = require("impetus.commands")
local hover = require("impetus.hover")
local complete = require("impetus.complete")
local lint = require("impetus.lint")
local highlight = require("impetus.highlight")
local side_help = require("impetus.side_help")
local actions = require("impetus.actions")
local info = require("impetus.info")
local intrinsic = require("impetus.intrinsic")

local M = {}
local dev_state = {
  plugin_mtime = -1,
  help_mtime = -1,
  reloading = false,
}
local blink_sort_patched = false

local function get_blink()
  local ok, blink = pcall(require, "blink.cmp")
  if not ok then
    return nil
  end
  return blink
end

local function ensure_blink_sort_for_impetus()
  if blink_sort_patched then
    return
  end
  local blink = get_blink()
  if not blink or type(blink.setup) ~= "function" then
    return
  end
  -- Force deterministic order for Impetus completion items.
  -- 【改进】同时配置 sources 以启用 impetus_kw
  pcall(blink.setup, {
    fuzzy = {
      sorts = { "sort_text", "label" },
    },
    sources = {
      default = { "impetus_kw" },
      providers = {
        impetus_kw = {
          name = "ImpetusKeywords",
          module = "impetus.blink_source",
        },
      },
    },
  })
  blink_sort_patched = true
end

local function safe_map(mode, lhs, rhs, opts)
  if rhs == nil then
    return
  end
  vim.keymap.set(mode, lhs, rhs, opts)
end

local function feed(key)
  return vim.api.nvim_replace_termcodes(key, true, false, true)
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_number_prefix(line)
  return (line:gsub("^%s*%d+%.%s*", ""))
end

local function parse_keyword(line)
  local normalized = trim(strip_number_prefix(line))
  return normalized:match("^(%*[%w_%-]+)")
end

local function is_separator_or_meta(line)
  local normalized = trim(strip_number_prefix(line))
  if normalized == "" then
    return true
  end
  if normalized:sub(1, 1) == "#" then
    return true
  end
  if normalized:sub(1, 1) == "$" then
    return true
  end
  if normalized == "Variable         Description" then
    return true
  end
  if normalized == '"Optional title"' or normalized:match('^".*"$') then
    return true
  end
  if normalized:match("^%-+$") then
    return true
  end
  if normalized:sub(1, 1) == "~" then
    return true
  end
  return false
end

local function is_title_line(line)
  local normalized = trim(strip_number_prefix(line or ""))
  return normalized == '"Optional title"' or normalized:match('^".*"$')
end

local function find_keyword_block(lines, row)
  local start_row = nil
  local keyword = nil
  for r = row, 1, -1 do
    local kw = parse_keyword(lines[r] or "")
    if kw then
      start_row = r
      keyword = kw
      break
    end
  end
  if not start_row then
    return nil
  end
  local end_row = #lines
  for r = start_row + 1, #lines do
    if parse_keyword(lines[r] or "") then
      end_row = r - 1
      break
    end
  end
  return { keyword = keyword, start_row = start_row, end_row = end_row }
end

local function collect_data_rows(lines, block)
  local rows = {}
  for r = block.start_row + 1, block.end_row do
    local line = lines[r] or ""
    if not is_separator_or_meta(line) then
      rows[#rows + 1] = r
    end
  end
  return rows
end

local function find_next_comma_outside_quotes(line, start_col1)
  local in_quotes = false
  local i = math.max(1, start_col1 or 1)
  while i <= #line do
    local ch = line:sub(i, i)
    if ch == '"' then
      in_quotes = not in_quotes
    elseif ch == "," and not in_quotes then
      return i
    end
    i = i + 1
  end
  return nil
end

local function count_commas_outside_quotes(line)
  local in_quotes = false
  local count = 0
  for i = 1, #line do
    local ch = line:sub(i, i)
    if ch == '"' then
      in_quotes = not in_quotes
    elseif ch == "," and not in_quotes then
      count = count + 1
    end
  end
  return count
end

local function field_starts_for_line(line)
  local starts = {}
  local indent = line:match("^(%s*)") or ""
  starts[#starts + 1] = #indent + 1

  local i = 1
  while true do
    local comma = find_next_comma_outside_quotes(line, i)
    if not comma then
      break
    end
    local next_pos = comma + 1
    while next_pos <= #line and line:sub(next_pos, next_pos) == " " do
      next_pos = next_pos + 1
    end
    if next_pos <= #line then
      starts[#starts + 1] = next_pos
    end
    i = comma + 1
  end
  return starts
end

local function jump_to_first_field(lines, row)
  local line = lines[row] or ""
  if line == "" then
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    return true
  end
  local first_non_space = line:find("%S") or 1
  vim.api.nvim_win_set_cursor(0, { row, first_non_space - 1 })
  return true
end

local function current_data_row_index(data_rows, row)
  for i, r in ipairs(data_rows) do
    if r == row then
      return i
    end
  end
  return nil
end

local function expected_fields_for_row(keyword, row_index)
  local entry = store.get_keyword(keyword)
  if not entry or not entry.signature_rows or #entry.signature_rows == 0 then
    return nil
  end
  if entry.signature_rows[row_index] then
    return #entry.signature_rows[row_index]
  end
  return #entry.signature_rows[#entry.signature_rows]
end

local function jump_after_comma(line, comma_pos, row, current_col1)
  local target = comma_pos + 1
  while target <= #line and line:sub(target, target) == " " do
    target = target + 1
  end
  if target > #line then
    return false
  end
  if current_col1 and target <= current_col1 then
    return false
  end
  vim.api.nvim_win_set_cursor(0, { row, math.max(target - 1, 0) })
  return true
end

local function generic_field_jump(lines, row, col1)
  local line = lines[row] or ""
  local next_comma = find_next_comma_outside_quotes(line, col1)
  if next_comma then
    if jump_after_comma(line, next_comma, row, col1) then
      return true
    end
  end
  -- Fallback for space-delimited rows: jump to next token, not inside the current token.
  local i = col1 + 1
  while i <= #line and not line:sub(i, i):match("[%s,]") do
    i = i + 1
  end
  while i <= #line and line:sub(i, i):match("[%s,]") do
    i = i + 1
  end
  if i <= #line then
    vim.api.nvim_win_set_cursor(0, { row, math.max(i - 1, 0) })
    return true
  end
  for r = row + 1, #lines do
    local l = lines[r] or ""
    local t = trim(l)
    if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" and t:sub(1, 1) ~= "*" and t:sub(1, 1) ~= "~" then
      local first = l:find("%S") or 1
      vim.api.nvim_win_set_cursor(0, { r, math.max(first - 1, 0) })
      return true
    end
  end
  return false
end

local function try_blink_select_next()
  local blink = get_blink()
  if not blink or not blink.is_menu_visible() then
    return false
  end
  local ok, moved = pcall(blink.select_next, { auto_insert = false })
  return ok and moved == true
end

local function try_blink_select_prev()
  local blink = get_blink()
  if not blink or not blink.is_menu_visible() then
    return false
  end
  local ok, moved = pcall(blink.select_prev, { auto_insert = false })
  return ok and moved == true
end

local function try_blink_accept()
  local blink = get_blink()
  if not blink or not blink.is_menu_visible() then
    return false
  end
  local ok, accepted = pcall(blink.select_and_accept)
  return ok and accepted == true
end

local function goto_next_field_non_snippet(allow_insert_delim)
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local line = lines[row] or ""
  local col1 = col0 + 1

  local block = find_keyword_block(lines, row)
  if not block then
    return generic_field_jump(lines, row, col1)
  end

  -- Special-case title row: allow tab to stay on/edit title, then continue to first parameter row.
  if is_title_line(line) then
    for r = row + 1, block.end_row do
      local l = lines[r] or ""
      if not is_separator_or_meta(l) then
        return jump_to_first_field(lines, r)
      end
    end
    return generic_field_jump(lines, row, col1)
  end

  -- If we're on a data line, try next field on the same line first.
  if not is_separator_or_meta(line) then
    local next_comma = find_next_comma_outside_quotes(line, col1)
    if next_comma then
      if jump_after_comma(line, next_comma, row, col1) then
        return true
      end
    end
  end

  -- Otherwise jump to next data row in the same keyword block.
  local data_rows = collect_data_rows(lines, block)
  if #data_rows == 0 then
    return generic_field_jump(lines, row, col1)
  end

  local row_idx = current_data_row_index(data_rows, row)

  -- If we're not on a data row, jump to the next one in this block.
  if not row_idx then
    if row == block.start_row then
      local next_line = lines[row + 1] or ""
      if is_title_line(next_line) then
        return jump_to_first_field(lines, row + 1)
      end
    end
    for _, r in ipairs(data_rows) do
      if r > row then
        return jump_to_first_field(lines, r)
      end
    end
    return false
  end

  local expected_fields = expected_fields_for_row(block.keyword, row_idx)
  local starts = field_starts_for_line(line)
  local cursor_col1 = col0 + 1

  -- Try moving to next recognized field start on current row.
  for _, s in ipairs(starts) do
    if s > cursor_col1 then
      vim.api.nvim_win_set_cursor(0, { row, math.max(s - 1, 0) })
      return true
    end
  end

  -- If schema expects more fields than currently present, append delimiter in insert mode.
  -- Use comma-count based field count to avoid infinite append when trailing empty field exists.
  if allow_insert_delim and expected_fields then
    local comma_count = count_commas_outside_quotes(line)
    local current_fields = comma_count + 1
    if current_fields < expected_fields then
      local new_line = line .. ",  "
      vim.api.nvim_buf_set_lines(0, row - 1, row, false, { new_line })
      local new_starts = field_starts_for_line(new_line)
      local target = new_starts[#new_starts] or (#new_line + 1)
      vim.api.nvim_win_set_cursor(0, { row, math.max(target - 1, 0) })
      return true
    end
  end

  -- Current row done: jump to next data row first field.
  for i = row_idx + 1, #data_rows do
    local r = data_rows[i]
    if r then
      return jump_to_first_field(lines, r)
    end
  end

  -- Last row in block: no jump target.
  return generic_field_jump(lines, row, col1)
end

function M.jump_next_field()
  return goto_next_field_non_snippet()
end

function M.tab_expr_insert()
  local blink = get_blink()
  if blink and blink.snippet_active({ direction = 1 }) then
    blink.snippet_forward()
    return ""
  end
  if vim.fn.pumvisible() == 1 then
    return feed("<C-n>")
  end
  if goto_next_field_non_snippet(true) then
    return ""
  end
  return "\t"
end

function M.tab_expr_normal()
  if goto_next_field_non_snippet(false) then
    return ""
  end
  return "w"
end

function M.handle_tab_insert()
  local blink = get_blink()
  if blink and blink.snippet_active({ direction = 1 }) then
    blink.snippet_forward()
    return true
  end
  return goto_next_field_non_snippet(true)
end

function M.handle_tab_normal()
  local before = vim.api.nvim_win_get_cursor(0)
  local moved = goto_next_field_non_snippet(false)
  local after = vim.api.nvim_win_get_cursor(0)
  if moved and (before[1] ~= after[1] or before[2] ~= after[2]) then
    return true
  end
  return false
end

local function resolve_default_help_file()
  local cwd_path = vim.fn.getcwd() .. "/commands.help"
  if vim.fn.filereadable(cwd_path) == 1 then
    return cwd_path
  end
  return nil
end

local function bundled_db_path()
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
  return root .. "/data/keywords.json"
end

local function plugin_root_path()
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
end

local function latest_plugin_mtime()
  local root = plugin_root_path()
  local patterns = {
    "lua/impetus/*.lua",
    "plugin/*.lua",
    "ftplugin/*.vim",
    "ftdetect/*.vim",
    "syntax/*.vim",
    "after/syntax/*.vim",
  }
  local latest = -1
  for _, p in ipairs(patterns) do
    local files = vim.fn.globpath(root, p, false, true)
    for _, f in ipairs(files) do
      local mt = vim.fn.getftime(f)
      if mt and mt > latest then
        latest = mt
      end
    end
  end
  return latest
end

local function setup_dev_hot_reload()
  if not config.get().dev_hot_reload then
    return
  end

  dev_state.plugin_mtime = latest_plugin_mtime()
  local hp = store.get_path() or config.get().help_file
  if hp and hp ~= "" then
    dev_state.help_mtime = vim.fn.getftime(hp)
  end

  local group = vim.api.nvim_create_augroup("ImpetusDevHotReload", { clear = true })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      if dev_state.reloading then
        return
      end
      dev_state.reloading = true

      local should_reload_plugin = false
      local now_plugin_mtime = latest_plugin_mtime()
      if now_plugin_mtime > dev_state.plugin_mtime then
        should_reload_plugin = true
        dev_state.plugin_mtime = now_plugin_mtime
      end

      local should_reload_help = false
      local help_path = store.get_path() or config.get().help_file or resolve_default_help_file()
      if help_path and help_path ~= "" and vim.fn.filereadable(help_path) == 1 then
        local now_help_mtime = vim.fn.getftime(help_path)
        if now_help_mtime > dev_state.help_mtime then
          should_reload_help = true
          dev_state.help_mtime = now_help_mtime
        end
      end

      if should_reload_plugin or should_reload_help then
        commands.dev_refresh({
          reload_plugin = should_reload_plugin,
          reload_help = should_reload_help,
          quiet = true,
        })
      end

      dev_state.reloading = false
    end,
  })
end

local function try_bootstrap_db()
  local opts = config.get()
  local help_path = opts.help_file or resolve_default_help_file()
  if help_path and vim.fn.filereadable(help_path) == 1 then
    local ok = store.load_from_file(help_path)
    if ok then
      store.save_cache(opts.cache_file)
      return
    end
  end
  if store.load_cache(opts.cache_file) then
    return
  end
  local bundled = bundled_db_path()
  if vim.fn.filereadable(bundled) == 1 then
    store.load_cache(bundled)
  end
end

local function setup_filetype_behaviors()
  local group = vim.api.nvim_create_augroup("ImpetusPlugin", { clear = true })

  local function ensure_impetus_filetype(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      return
    end
    local name = (vim.api.nvim_buf_get_name(buf) or ""):lower()
    if name:match("%.k$") or name:match("%.key$") or name:match("%.imp$") or name:match("%.inp$") then
      if vim.bo[buf].filetype ~= "impetus" then
        vim.bo[buf].filetype = "impetus"
      end
    end
  end

  local function ensure_impetus_syntax(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      return
    end
    if vim.bo[buf].filetype ~= "impetus" then
      return
    end
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent! syntax clear")
      vim.cmd("silent! unlet! b:current_syntax")
      vim.cmd("silent! runtime! syntax/impetus.vim")
    end)
  end

  local function refresh_main_visuals(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      return
    end
    if vim.b[buf].impetus_help_buffer == 1 or vim.b[buf].impetus_info_buffer == 1 then
      return
    end
    ensure_impetus_filetype(buf)
    if vim.bo[buf].filetype ~= "impetus" then
      return
    end
    ensure_impetus_syntax(buf)
    highlight.apply()
    vim.b[buf].impetus_intrinsic_applied = 0
    intrinsic.apply_syntax_for_current_buffer()
  end

  local function focus_first_keyword_in_window(win, buf)
    if not (win and vim.api.nvim_win_is_valid(win) and buf and vim.api.nvim_buf_is_valid(buf)) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local row = nil
    for i, line in ipairs(lines) do
      if parse_keyword(line or "") then
        row = i
        break
      end
    end
    if not row then
      return
    end
    pcall(vim.api.nvim_set_current_win, win)
    pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
  end

  local function focus_main_window_first_keyword()
    local target_win, target_buf = nil, nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) then
        local b = vim.api.nvim_win_get_buf(w)
        if vim.api.nvim_buf_is_valid(b) then
          local ft = vim.bo[b].filetype
          if (ft == "impetus" or ft == "kwt")
            and vim.w[w].impetus_nav_window ~= 1
            and vim.w[w].impetus_child_window ~= 1
            and vim.b[b].impetus_help_buffer ~= 1
            and vim.b[b].impetus_info_buffer ~= 1
          then
            target_win, target_buf = w, b
            break
          end
        end
      end
    end
    if target_win and target_buf then
      focus_first_keyword_in_window(target_win, target_buf)
    end
  end

  local function restore_main_return_or_first_keyword()
    local rc = vim.g.impetus_main_return
    if type(rc) == "table" and rc.win and vim.api.nvim_win_is_valid(rc.win) then
      local b = vim.api.nvim_win_get_buf(rc.win)
      if b == rc.buf and vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_set_current_win, rc.win)
        if rc.row and rc.row >= 1 then
          pcall(vim.api.nvim_win_set_cursor, rc.win, { rc.row, rc.col or 0 })
        end
        vim.g.impetus_main_return = nil
        return
      end
    end
    vim.g.impetus_main_return = nil
    focus_main_window_first_keyword()
  end

  local function focus_first_keyword_once(buf)
    if vim.b[buf].impetus_initial_focus_done == 1 then
      return
    end
    local target_win = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
        if vim.w[w].impetus_nav_window ~= 1 and vim.w[w].impetus_child_window ~= 1 then
          target_win = w
          break
        end
      end
    end
    if not target_win then
      return
    end
    local row = nil
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(lines) do
      if parse_keyword(line or "") then
        row = i
        break
      end
    end
    if not row then
      vim.b[buf].impetus_initial_focus_done = 1
      return
    end
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(target_win) and vim.api.nvim_win_get_buf(target_win) == buf then
        focus_first_keyword_in_window(target_win, buf)
      end
      vim.b[buf].impetus_initial_focus_done = 1
    end)
  end

  local function attach_behaviors(buf)
    ensure_impetus_filetype(buf)
    if vim.b[buf].impetus_help_buffer == 1 then
      return
    end
    if vim.b[buf].impetus_info_buffer == 1 then
      return
    end
    local already_attached = (vim.b[buf].impetus_attached == 1)
    if not already_attached then
      vim.b[buf].impetus_attached = 1
      vim.b[buf].impetus_fold_all_closed = 0
    end

    ensure_blink_sort_for_impetus()
    if not already_attached then
      refresh_main_visuals(buf)
      if config.get().side_help_track then
        side_help.attach_buffer(buf)
      end
      if vim.b[buf].impetus_child_buffer ~= 1 then
        focus_first_keyword_once(buf)
      end
      vim.bo[buf].omnifunc = "v:lua.require'impetus.complete'.omnifunc"
    end
    safe_map("n", "K", hover.show_under_cursor, { buffer = buf, silent = true, desc = "Impetus docs under cursor" })
    safe_map("n", "gd", "<Cmd>ImpetusParamDef<CR>", { buffer = buf, silent = true, desc = "Impetus param definition" })
    safe_map("n", "gr", "<Cmd>ImpetusParamRefs<CR>", { buffer = buf, silent = true, desc = "Impetus param references" })
    safe_map("n", "<localleader>c", actions.toggle_comment_block, { buffer = buf, silent = true, desc = "Toggle comment keyword block" })
    safe_map("n", "dk", actions.delete_block, { buffer = buf, silent = true, desc = "Cut current block to register" })
    safe_map("n", "<localleader>y", actions.copy_block_below, { buffer = buf, silent = true, desc = "Yank current block to register" })
    safe_map("n", "<localleader>j", actions.move_block_down, { buffer = buf, silent = true, desc = "Move keyword block down" })
    safe_map("n", "<localleader>k", actions.move_block_up, { buffer = buf, silent = true, desc = "Move keyword block up" })
    safe_map("n", "<localleader>n", actions.goto_next_keyword, { buffer = buf, silent = true, desc = "Next keyword" })
    safe_map("n", "<localleader>N", actions.goto_prev_keyword, { buffer = buf, silent = true, desc = "Prev keyword" })
    safe_map("n", "<localleader>f", actions.toggle_all_keyword_folds, { buffer = buf, silent = true, desc = "Toggle fold all keyword blocks" })
    safe_map("n", "<localleader>t", actions.toggle_keyword_fold_here, { buffer = buf, silent = true, desc = "Toggle current keyword fold" })
    safe_map("n", "<localleader>F", actions.toggle_all_control_folds, { buffer = buf, silent = true, desc = "Toggle fold all control blocks" })
    safe_map("n", "<localleader>T", actions.toggle_control_fold_here, { buffer = buf, silent = true, desc = "Toggle current control block fold" })
    safe_map("n", "<localleader>z", actions.toggle_all_folds, { buffer = buf, silent = true, desc = "Toggle fold all keyword + control blocks" })
    safe_map("n", "<localleader>m", actions.jump_match_block, { buffer = buf, silent = true, desc = "Jump to matching control block" })
    safe_map("n", "<localleader>b", actions.check_blocks, { buffer = buf, silent = true, desc = "Check unmatched control blocks" })
    safe_map("n", "%", function()
      if not actions.jump_match_block() then
        vim.cmd("normal! %")
      end
    end, { buffer = buf, silent = true, desc = "Match jump (directive/brackets)" })
    safe_map("n", "<localleader>u", "<Cmd>ImpetusCheatSheet<CR>", { buffer = buf, silent = true, desc = "Impetus quick help" })
    safe_map("n", "<localleader>h", actions.toggle_help, { buffer = buf, silent = true, desc = "Toggle help pane" })
    safe_map("n", "<localleader><localleader>", actions.show_ref_completion, { buffer = buf, silent = true, desc = "Ref/Option completion" })
    safe_map("n", "<localleader>R", actions.show_ref_completion, { buffer = buf, silent = true, desc = "Ref/Option completion" })
    safe_map("i", "<localleader><localleader>", actions.show_ref_completion, { buffer = buf, silent = true, desc = "Ref/Option completion" })
    safe_map("i", "<localleader>R", actions.show_ref_completion, { buffer = buf, silent = true, desc = "Ref/Option completion" })
    safe_map("n", "<localleader>i", "<Cmd>ImpetusInfo<CR>", { buffer = buf, silent = true, desc = "Toggle info pane" })
    safe_map("n", "<localleader>I", actions.insert_template_here, { buffer = buf, silent = true, desc = "Insert keyword template" })
    safe_map("n", "<localleader>r", "<Cmd>ImpetusReload<CR>", { buffer = buf, silent = true, desc = "Reload help database" })
    pcall(vim.keymap.del, "n", "<localleader>q", { buffer = buf })
    safe_map("n", "<localleader>q", "<Cmd>q!<CR>", { buffer = buf, silent = true, desc = "Quit current window (force)" })
    safe_map("n", "<localleader>Q", actions.close_popups, { buffer = buf, silent = true, desc = "Close popup/quickfix" })
    pcall(vim.keymap.del, "n", "<localleader>gf", { buffer = buf })
    pcall(vim.keymap.del, "i", "<localleader>gf", { buffer = buf })
    safe_map("n", "<localleader>o", actions.open_include_under_cursor, { buffer = buf, silent = true, desc = "Open include/script file (left split)" })
    safe_map("n", "<localleader>O", actions.open_in_gui, { buffer = buf, silent = true, desc = "Open in Impetus GUI" })
    vim.keymap.set("i", "<C-Space>", function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n", false)
    end, { buffer = buf, silent = true, desc = "Impetus complete" })
    vim.keymap.set({ "i", "s" }, "<Space>", function()
      if vim.fn.pumvisible() == 1 then
        return feed("<C-y>")
      end
      return " "
    end, { buffer = buf, expr = true, silent = true, desc = "Accept completion with Space" })

    if config.get().tab_field_jump then
      vim.keymap.set({ "i", "s" }, "<Tab>", function()
        if not M.handle_tab_insert() then
          vim.api.nvim_feedkeys(feed("<Tab>"), "n", false)
        end
      end, { buffer = buf, silent = true, desc = "Next Impetus field" })

      vim.keymap.set("n", "<Tab>", function()
        if not M.handle_tab_normal() then
          vim.api.nvim_feedkeys("w", "n", false)
        end
      end, { buffer = buf, silent = true, desc = "Next Impetus field (normal)" })
    end

    if not already_attached then
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
          vim.wo[win].foldlevel = 99
          vim.wo[win].foldenable = true
          vim.api.nvim_win_call(win, function()
            vim.cmd("silent! normal! zR")
          end)
        end
      end
    end

    if config.get().blink_menu_keys then
      vim.keymap.set({ "i", "s" }, "j", function()
        if try_blink_select_next() then
          return ""
        end
        return "j"
      end, { buffer = buf, expr = true, silent = true, desc = "Blink next (Impetus)" })

      vim.keymap.set({ "i", "s" }, "k", function()
        if try_blink_select_prev() then
          return ""
        end
        return "k"
      end, { buffer = buf, expr = true, silent = true, desc = "Blink prev (Impetus)" })

      vim.keymap.set({ "i", "s" }, "<Down>", function()
        if try_blink_select_next() then
          return ""
        end
        return feed("<Down>")
      end, { buffer = buf, expr = true, silent = true, desc = "Blink next (Down)" })

      vim.keymap.set({ "i", "s" }, "<Up>", function()
        if try_blink_select_prev() then
          return ""
        end
        return feed("<Up>")
      end, { buffer = buf, expr = true, silent = true, desc = "Blink prev (Up)" })

      vim.keymap.set({ "i", "s" }, "<Space>", function()
        if vim.fn.pumvisible() == 1 then
          return feed("<C-y>")
        end
        if try_blink_accept() then
          return ""
        end
        return " "
      end, { buffer = buf, expr = true, silent = true, desc = "Blink accept (Impetus)" })
    end
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = config.get().filetypes,
    callback = function(ev)
      ensure_impetus_filetype(ev.buf)
      attach_behaviors(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    pattern = { "*.k", "*.key", "*.imp", "*.inp" },
    callback = function(ev)
      ensure_impetus_filetype(ev.buf)
      attach_behaviors(ev.buf)
    end,
  })

  -- Filetype-driven fallback: for buffers manually set to `impetus` without
  -- .k/.key suffix, still attach behaviors and apply palette consistently.
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    pattern = "*",
    callback = function(ev)
      local ft = vim.bo[ev.buf].filetype
      if ft == "impetus" or ft == "kwt" then
        attach_behaviors(ev.buf)
      end
    end,
  })

  if config.get().lint_on_save then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      pattern = { "*.key", "*.k", "*.imp", "*.inp" },
      callback = function(ev)
        lint.run(ev.buf)
      end,
    })
  end

  if config.get().blink_retrigger_on_star then
    vim.api.nvim_create_autocmd("TextChangedI", {
      group = group,
      callback = function()
        local ft = vim.bo.filetype
        if not vim.tbl_contains(config.get().filetypes, ft) then
          return
        end
        local blink = get_blink()
        if not blink or blink.is_menu_visible() then
          return
        end
        local line = vim.api.nvim_get_current_line()
        local col = vim.fn.col(".") - 1
        if col < 1 then
          return
        end
        local left = line:sub(1, col)
        if left:match("%*$") then
          blink.show()
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      local ft = vim.bo.filetype
      if vim.tbl_contains(config.get().filetypes, ft) then
        refresh_main_visuals(vim.api.nvim_get_current_buf())
      end
    end,
  })

  vim.api.nvim_create_autocmd("Syntax", {
    group = group,
    pattern = { "impetus", "kwt" },
    callback = function()
      local ft = vim.bo.filetype
      if vim.tbl_contains(config.get().filetypes, ft) then
        vim.b.impetus_intrinsic_applied = 0
        highlight.apply()
        intrinsic.apply_syntax_for_current_buffer()
      end
    end,
  })

  -- Keep main editing buffer colors consistent with side panes by reapplying
  -- our highlight palette whenever entering an Impetus-like buffer.
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "FileType" }, {
    group = group,
    pattern = { "*.k", "*.key", "*.imp", "*.inp", "impetus", "kwt" },
    callback = function(ev)
      ensure_impetus_filetype(ev.buf)
      local ft = vim.bo[ev.buf].filetype
      if ft == "impetus" or ft == "kwt" then
        refresh_main_visuals(ev.buf)
      end
    end,
  })

  -- Startup consistency: colorscheme or runtime scripts may override our groups
  -- before normal editing begins. Re-apply once after UI is fully ready.
  vim.api.nvim_create_autocmd({ "VimEnter", "BufReadPost" }, {
    group = group,
    pattern = { "*.k", "*.key", "*.imp", "*.inp" },
    callback = function(ev)
      vim.schedule(function()
        refresh_main_visuals(ev.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local closed = tonumber(ev.match)
      local last_child = tonumber(vim.g.impetus_last_child_win or -1)
      if not closed or closed ~= last_child then
        return
      end
      vim.g.impetus_last_child_win = -1
      vim.schedule(function()
        restore_main_return_or_first_keyword()
      end)
    end,
  })
end

function M.setup(opts)
  config.setup(opts)
  commands.register()
  if config.get().side_help_track then
    side_help.setup()
  end
  info.setup()
  setup_dev_hot_reload()
  setup_filetype_behaviors()
  -- Global fallback: keep `,h` usable even when focus is in info/help/nav windows.
  vim.keymap.set("n", ",h", function()
    require("impetus.actions").toggle_help()
  end, { silent = true, desc = "Impetus help toggle (,h global literal)" })
  vim.keymap.set("n", "<leader>h", function()
    require("impetus.actions").toggle_help()
  end, { silent = true, desc = "Impetus help toggle (global)" })
  if config.get().auto_load then
    try_bootstrap_db()
  end
end

return M
