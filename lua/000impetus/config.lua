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
