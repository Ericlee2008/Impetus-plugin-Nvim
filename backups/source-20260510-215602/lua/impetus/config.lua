local M = {}

local defaults = {
  help_file = nil,
  auto_load = true,
  cache_file = nil,
  lint_on_save = true,
  filetypes = { "impetus" },
  blink_retrigger_on_star = true,
  blink_menu_keys = false,
  tab_field_jump = true,
  side_help_track = true,
  side_help_width = 68,
  ref_marks = true,
  dev_hot_reload = true,
  dev_mode = false,
  geometry_preview = {
    enabled = true,
    python_exe = "pyw",
    python_args = { "-3" },
    viewer_script = nil,
  },
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
