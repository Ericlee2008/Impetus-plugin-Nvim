
vim.filetype.add({
  extension = {
    k = "impetus",
    key = "impetus",
    },
  pattern = {
    [".*/doc/commands%.help"] = "impetus",
    [".*\\doc\\commands%.help"] = "impetus",
  },
})