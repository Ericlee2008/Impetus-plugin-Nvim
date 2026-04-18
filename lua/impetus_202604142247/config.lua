local M = {}

local defaults = {
  help_file = nil,
  auto_load = true,
  cache_file = nil,
  lint_on_save = true,
  filetypes = { "impetus", "kwt" },
  blink_retrigger_on_star = true,
  blink_menu_keys = false,
  tab_field_jump = true,
  side_help_track = true,
  side_help_width = 68,
  dev_hot_reload = true,
  dev_mode = false,

  -- Info Window v2 configuration (新设计)
  use_info_v2 = false,              -- 使用新版本 Info 窗口 (默认关闭)
  info_v2_mode = 'miniature',       -- 启动模式: 'miniature' | 'expanded'
  info_v2_expand_key = '<Leader>i', -- 展开/收起快捷键
  info_v2_miniature_height = 1,     -- 迷你模式高度
  info_v2_expanded_height = 20,     -- 展开模式高度
  info_v2_expanded_width = 120,     -- 展开模式宽度
}

local state = {
  options = vim.deepcopy(defaults),
}

function M.setup(opts)
  state.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get()
  return state.options
end

return M
