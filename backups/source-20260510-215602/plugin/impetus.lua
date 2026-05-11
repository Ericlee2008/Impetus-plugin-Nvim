if vim.g.loaded_impetus_nvim == 1 then
  return
end
vim.g.loaded_impetus_nvim = 1

require("impetus.profile").startup_mark("plugin/impetus.lua loaded")
require("impetus").setup()
require("impetus.profile").flush_startup()
