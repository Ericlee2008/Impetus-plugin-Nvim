if vim.g.loaded_impetus_nvim == 1 then
  return
end
vim.g.loaded_impetus_nvim = 1

require("impetus").setup()
