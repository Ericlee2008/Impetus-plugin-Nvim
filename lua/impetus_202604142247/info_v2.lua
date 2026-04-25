-- =============================================================================
-- Info Window v2: Miniature Mode + Expanded Mode + Context-Aware
-- =============================================================================
-- Design: https://github.com/user/impetus.nvim/discussions/info-redesign
--
-- Features:
--   1. Miniature mode (default): Single-line summary, minimal space
--   2. Expanded mode: Three-column layout (File Tree | Stats | Keywords)
--   3. Context-aware: Auto-update based on cursor position
--
-- Usage:
--   require('impetus.info_v2').open_miniature(buf, win)
--   require('impetus.info_v2').toggle_expanded(buf, win)
--   require('impetus.info_v2').update_context(buf, win)
-- =============================================================================

local M = {}

-- ═════════════════════════════════════════════════════════════════════════
-- State Management
-- ═════════════════════════════════════════════════════════════════════════

local state = {
  mode = 'closed',              -- 'miniature' | 'expanded' | 'closed'
  miniature_win = nil,          -- Window ID for miniature mode
  expanded_win = nil,           -- Window ID for expanded mode
  miniature_buf = nil,          -- Buffer ID for miniature mode
  expanded_buf = nil,           -- Buffer ID for expanded mode

  -- Context tracking
  current_context = nil,        -- 'keyword' | 'file' | 'overview'
  selected_keyword = nil,
  selected_file = nil,

  -- Config
  expand_key = '<Leader>i',
  miniature_height = 1,
  expanded_height = 20,
  expanded_width = 120,
}

local config = require('impetus.config')

-- ═════════════════════════════════════════════════════════════════════════
-- Utilities
-- ═════════════════════════════════════════════════════════════════════════

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_model_name(buf)
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t:r')
  return name ~= "" and name or "unknown"
end

-- ═════════════════════════════════════════════════════════════════════════
-- Miniature Mode (Single-line summary)
-- ═════════════════════════════════════════════════════════════════════════

local function build_tree(path, lines, visited)
  -- Simplified version - full implementation from info.lua
  visited = visited or {}
  if visited[path:lower()] then
    return { path = path, children = {}, parsed = { total_keywords = 0, total_parameters = 0, total_lines = 0, keywords = {} }, skipped = true }
  end
  visited[path:lower()] = true

  local parsed = { keywords = {}, includes = {}, parameters = {}, total_keywords = 0, total_parameters = 0, total_lines = #lines, keywords = {} }
  local children = {}

  for i, line in ipairs(lines) do
    local trimmed = trim(line):gsub("^%s*%d+%.%s*", "")
    local kw = trimmed:match("^(%*[%w_%-]+)")
    if kw then
      parsed.keywords[#parsed.keywords + 1] = { keyword = kw, row = i }
      parsed.total_keywords = parsed.total_keywords + 1
    end

    local param = trimmed:match("^%%?([%a_][%w_]*)%s*=")
    if param then
      parsed.parameters[#parsed.parameters + 1] = param
      parsed.total_parameters = parsed.total_parameters + 1
    end
  end

  return {
    path = path,
    children = children,
    parsed = parsed,
  }
end

local function aggregate_model_stats(node, acc)
  acc = acc or { total = 0, uniq = {}, parameters = 0, lines = 0, include_files = 0 }
  if node and node.parsed then
    acc.total = acc.total + (node.parsed.total_keywords or 0)
    acc.parameters = acc.parameters + (node.parsed.total_parameters or 0)
    acc.lines = acc.lines + (node.parsed.total_lines or 0)
    for _, k in ipairs(node.parsed.keywords or {}) do
      if k.keyword then
        acc.uniq[k.keyword:upper()] = true
      end
    end
  end
  for _, ch in ipairs((node and node.children) or {}) do
    if not ch.skipped then
      acc.include_files = acc.include_files + 1
    end
    aggregate_model_stats(ch, acc)
  end
  return acc
end

local function get_model_stats(buf)
  local root_file = vim.api.nvim_buf_get_name(buf)
  if root_file == "" then
    return nil
  end

  local root_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local root = build_tree(root_file, root_lines, {})
  local model_stats = aggregate_model_stats(root, nil)

  local model_unique = 0
  for _ in pairs(model_stats.uniq) do
    model_unique = model_unique + 1
  end

  return {
    keyword_count = model_stats.total,
    unique_types = model_unique,
    line_count = model_stats.lines,
    parameter_count = model_stats.parameters,
    file_count = model_stats.include_files,
  }
end

local function create_miniature_content(buf)
  local model_name = get_model_name(buf)
  local stats = get_model_stats(buf)

  if not stats then
    return { "Model: " .. model_name .. " │ [error loading stats]" }
  end

  local line = string.format(
    "Model: %s │ KW:%d │ Types:%d │ Lines:%d │ [⬇ expand]",
    model_name, stats.keyword_count, stats.unique_types, stats.line_count
  )

  return { line }
end

local function render_miniature(buf, win)
  -- Create or get miniature buffer
  if not state.miniature_buf or not vim.api.nvim_buf_is_valid(state.miniature_buf) then
    state.miniature_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.miniature_buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(state.miniature_buf, 'bufhidden', 'hide')
  end

  -- Temporarily set modifiable to write content
  vim.api.nvim_buf_set_option(state.miniature_buf, 'modifiable', true)

  local content = create_miniature_content(buf)
  vim.api.nvim_buf_set_lines(state.miniature_buf, 0, -1, false, content)

  -- Set to readonly after writing
  vim.api.nvim_buf_set_option(state.miniature_buf, 'modifiable', false)

  return state.miniature_buf
end

-- ═════════════════════════════════════════════════════════════════════════
-- Expanded Mode (Three-column layout)
-- ═════════════════════════════════════════════════════════════════════════

local function format_tree_line(prefix, name, col1_width)
  -- Format tree line, ensure left column width is fixed
  local line = prefix .. name
  local padding = col1_width - #line
  if padding > 0 then
    line = line .. string.rep(" ", padding)
  end
  return line
end

local function get_unique_keywords(node, uniq_map)
  -- Recursively collect all unique keywords
  uniq_map = uniq_map or {}
  if node and node.parsed then
    for _, kw in ipairs(node.parsed.keywords or {}) do
      if kw.keyword then
        uniq_map[kw.keyword:upper()] = true
      end
    end
  end
  for _, ch in ipairs((node and node.children) or {}) do
    get_unique_keywords(ch, uniq_map)
  end
  return uniq_map
end

local function create_expanded_content(buf)
  local root_file = vim.api.nvim_buf_get_name(buf)
  if root_file == "" then
    return { "Error: No file path" }
  end

  local root_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local root = build_tree(root_file, root_lines, {})
  local model_stats = aggregate_model_stats(root, nil)

  local model_unique = 0
  for _ in pairs(model_stats.uniq) do
    model_unique = model_unique + 1
  end

  -- Get all unique keywords
  local unique_keywords_map = get_unique_keywords(root, {})
  local keyword_list = {}
  for kw, _ in pairs(unique_keywords_map) do
    table.insert(keyword_list, kw)
  end
  table.sort(keyword_list)

  local lines = {}
  local col1_width = 25  -- File tree column width
  local col2_width = 22  -- Stats column width
  local separator = " │ "

  -- Title row
  table.insert(lines,
    format_tree_line("FILE TREE", "", col1_width) ..
    separator ..
    format_tree_line("FILE STATS", "", col2_width) ..
    separator ..
    "KEYWORDS"
  )

  -- Separator line
  table.insert(lines,
    string.rep("─", col1_width) ..
    separator:gsub(" ", "─") ..
    string.rep("─", col2_width) ..
    separator:gsub(" ", "─") ..
    string.rep("─", 40)
  )

  -- File tree and stats
  local tree_lines = {}
  local stats_lines = {}

  -- Generate file tree (simplified)
  local function add_tree_node(node, depth)
    local prefix = ""
    if depth > 0 then
      prefix = string.rep("│  ", depth - 1) .. "├─ "
    else
      prefix = "├─ "
    end

    local file_name = vim.fn.fnamemodify(node.path, ":t")
    table.insert(tree_lines, format_tree_line(prefix .. file_name, "", col1_width))

    -- Corresponding stats info
    local kw = node.parsed.total_keywords or 0
    local lines_count = node.parsed.total_lines or 0
    local stats_text = string.format("kw:%-4d lines:%d", kw, lines_count)
    table.insert(stats_lines, format_tree_line(stats_text, "", col2_width))

    for _, ch in ipairs(node.children or {}) do
      if not ch.skipped then
        add_tree_node(ch, depth + 1)
      end
    end
  end

  add_tree_node(root, 0)

  -- Keyword list
  local keyword_lines = {}
  for _, kw in ipairs(keyword_list) do
    table.insert(keyword_lines, "├─ " .. kw)
  end
  if #keyword_lines == 0 then
    table.insert(keyword_lines, "(no keywords)")
  end

  -- Merge three columns
  local max_rows = math.max(#tree_lines, #stats_lines, #keyword_lines)
  for i = 1, max_rows do
    local tree_part = tree_lines[i] or string.rep(" ", col1_width)
    local stats_part = stats_lines[i] or string.rep(" ", col2_width)
    local kw_part = keyword_lines[i] or ""

    table.insert(lines, tree_part .. separator .. stats_part .. separator .. kw_part)
  end

  return lines
end

local function render_expanded(buf, win)
  -- Create or get expanded buffer
  if not state.expanded_buf or not vim.api.nvim_buf_is_valid(state.expanded_buf) then
    state.expanded_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.expanded_buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(state.expanded_buf, 'bufhidden', 'hide')
  end

  -- Temporarily set modifiable to write content
  vim.api.nvim_buf_set_option(state.expanded_buf, 'modifiable', true)

  local content = create_expanded_content(buf)
  vim.api.nvim_buf_set_lines(state.expanded_buf, 0, -1, false, content)

  -- Set to readonly after writing
  vim.api.nvim_buf_set_option(state.expanded_buf, 'modifiable', false)

  return state.expanded_buf
end

-- ═════════════════════════════════════════════════════════════════════════
-- Context-Aware Switching
-- ═════════════════════════════════════════════════════════════════════════

local function detect_context(buf, win)
  -- TODO: Detect cursor position and determine context
  -- Returns: 'keyword' | 'file' | 'overview'
  return 'overview'
end

local function update_context_display(buf, win)
  local context = detect_context(buf, win)

  if context == 'keyword' then
    -- Show keyword-specific info in expanded mode
    print("Context: Keyword")
  elseif context == 'file' then
    -- Show file-specific info in expanded mode
    print("Context: File")
  else
    -- Show overview
    print("Context: Overview")
  end
end

-- ═════════════════════════════════════════════════════════════════════════
-- Window Management
-- ═════════════════════════════════════════════════════════════════════════

local function open_miniature_window(buf, win, miniature_buf)
  -- Close any existing windows first
  if state.miniature_win and vim.api.nvim_win_is_valid(state.miniature_win) then
    pcall(vim.api.nvim_win_close, state.miniature_win, true)
  end
  if state.expanded_win and vim.api.nvim_win_is_valid(state.expanded_win) then
    pcall(vim.api.nvim_win_close, state.expanded_win, true)
  end

  -- Get window dimensions
  local win_width = vim.fn.winwidth(0)
  local win_height = vim.fn.winheight(0)

  -- Create floating window at bottom of screen
  local miniature_win = vim.api.nvim_open_win(miniature_buf, false, {
    relative = 'cursor',
    row = win_height - 2,
    col = 0,
    width = math.min(win_width, 120),
    height = 1,
    style = 'minimal',
    border = 'rounded',
  })

  -- Set buffer options
  vim.api.nvim_buf_set_option(miniature_buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(miniature_buf, 'readonly', true)

  -- Add keybindings for the miniature window
  local opts = { noremap = true, silent = true, buffer = miniature_buf }
  vim.keymap.set('n', '<Leader>i', function()
    -- Use main window buffer, not miniature window buffer
    local main_buf = nil
    for _, win_id in ipairs(vim.api.nvim_list_wins()) do
      local buf_id = vim.api.nvim_win_get_buf(win_id)
      local buf_name = vim.api.nvim_buf_get_name(buf_id)
      -- Find the edited .k file, not nofile buffer
      if buf_name:match('%.k$') or buf_name:match('%.key$') then
        main_buf = buf_id
        break
      end
    end
    if main_buf then
      M.toggle_expanded(main_buf, vim.fn.win_getid(1))
    end
  end, opts)
  vim.keymap.set('n', 'q', function()
    M.close()
  end, opts)

  state.miniature_win = miniature_win
  return state.miniature_win
end

local function open_expanded_window(buf, win, expanded_buf)
  -- Close miniature window if open
  if state.miniature_win and vim.api.nvim_win_is_valid(state.miniature_win) then
    pcall(vim.api.nvim_win_close, state.miniature_win, true)
  end

  -- Close any existing expanded window
  if state.expanded_win and vim.api.nvim_win_is_valid(state.expanded_win) then
    pcall(vim.api.nvim_win_close, state.expanded_win, true)
  end

  -- Get screen dimensions
  local screen_width = vim.o.columns
  local screen_height = vim.o.lines

  -- Create floating window
  state.expanded_win = vim.api.nvim_open_win(expanded_buf, false, {
    relative = 'editor',
    row = 2,
    col = 2,
    width = math.min(screen_width - 4, state.expanded_width),
    height = math.min(screen_height - 6, state.expanded_height),
    style = 'minimal',
    border = 'rounded',
  })

  -- Set buffer options
  vim.api.nvim_buf_set_option(expanded_buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(expanded_buf, 'readonly', true)

  -- Add keybindings for the expanded window
  local opts = { noremap = true, silent = true, buffer = expanded_buf }
  vim.keymap.set('n', '<Leader>i', function()
    -- Use main window buffer
    local main_buf = nil
    for _, win_id in ipairs(vim.api.nvim_list_wins()) do
      local buf_id = vim.api.nvim_win_get_buf(win_id)
      local buf_name = vim.api.nvim_buf_get_name(buf_id)
      if buf_name:match('%.k$') or buf_name:match('%.key$') then
        main_buf = buf_id
        break
      end
    end
    if main_buf then
      M.toggle_expanded(main_buf, vim.fn.win_getid(1))
    end
  end, opts)
  vim.keymap.set('n', 'q', function()
    M.close()
  end, opts)

  return state.expanded_win
end

-- ═════════════════════════════════════════════════════════════════════════
-- Public API
-- ═════════════════════════════════════════════════════════════════════════

function M.open_miniature(source_buf, source_win)
  if state.mode == 'miniature' then
    return  -- Already open
  end

  -- Close expanded if open
  if state.mode == 'expanded' then
    M.close_expanded()
  end

  local miniature_buf = render_miniature(source_buf, source_win)
  local miniature_win = open_miniature_window(source_buf, source_win, miniature_buf)

  state.mode = 'miniature'

  print("✨ Info window: Miniature mode (press " .. state.expand_key .. " to expand)")
end

function M.open_expanded(source_buf, source_win)
  if state.mode == 'expanded' then
    return  -- Already open
  end

  -- Close miniature if open
  if state.mode == 'miniature' then
    M.close_miniature()
  end

  local expanded_buf = render_expanded(source_buf, source_win)
  local expanded_win = open_expanded_window(source_buf, source_win, expanded_buf)

  state.mode = 'expanded'

  print("📊 Info window: Expanded mode (press " .. state.expand_key .. " to collapse)")
end

function M.toggle_expanded(source_buf, source_win)
  if state.mode == 'expanded' then
    M.open_miniature(source_buf, source_win)
  else
    M.open_expanded(source_buf, source_win)
  end
end

function M.close_miniature()
  if state.miniature_win and vim.api.nvim_win_is_valid(state.miniature_win) then
    vim.api.nvim_win_close(state.miniature_win, false)
    state.miniature_win = nil
  end
  state.mode = 'closed'
end

function M.close_expanded()
  if state.expanded_win and vim.api.nvim_win_is_valid(state.expanded_win) then
    vim.api.nvim_win_close(state.expanded_win, false)
    state.expanded_win = nil
  end
  state.mode = 'closed'
end

function M.close()
  M.close_miniature()
  M.close_expanded()
  state.mode = 'closed'
end

function M.update_context(source_buf, source_win)
  if state.mode == 'expanded' then
    update_context_display(source_buf, source_win)
  end
end

function M.set_mode(mode)
  if mode == 'miniature' or mode == 'expanded' or mode == 'closed' then
    state.mode = mode
  end
end

function M.get_mode()
  return state.mode
end

function M.is_open()
  return state.mode ~= 'closed'
end

-- ═════════════════════════════════════════════════════════════════════════
-- Integration with main plugin
-- ═════════════════════════════════════════════════════════════════════════

function M.setup()
  -- Get config values
  local cfg = config.get()
  state.expand_key = cfg.info_v2_expand_key or '<Leader>i'
  state.miniature_height = cfg.info_v2_miniature_height or 1
  state.expanded_height = cfg.info_v2_expanded_height or 20
  state.expanded_width = cfg.info_v2_expanded_width or 120

  print("✅ Info v2 module loaded (experimental)")
end

-- ═════════════════════════════════════════════════════════════════════════
-- Auto-open on file open
-- ═════════════════════════════════════════════════════════════════════════

function M.open_for_current()
  -- Open miniature mode for current buffer
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  M.open_miniature(buf, win)
end

function M.close_for_current()
  M.close()
end

function M.toggle_for_current()
  if M.is_open() then
    M.close()
  else
    M.open_for_current()
  end
end

return M
