-- param_selector_test.lua
-- Minimal test version

local M = {}

function M.test()
  print("[TEST] Starting param selector test")

  -- Test 1: Get current buffer
  local buf = vim.api.nvim_get_current_buf()
  print("[TEST] Current buffer: " .. buf)

  -- Test 2: Get cursor position
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  print("[TEST] Cursor position: row=" .. row .. ", col=" .. col)

  -- Test 3: Get current line
  local line = vim.api.nvim_get_current_line()
  print("[TEST] Current line: " .. line)

  -- Test 4: Try to get database
  local ok, store = pcall(require, "impetus.store")
  if ok then
    print("[TEST] Store module loaded successfully")
    local ok2, db = pcall(store.get_db)
    if ok2 and db then
      print("[TEST] Database loaded")
      local count = 0
      for k, v in pairs(db) do
        count = count + 1
      end
      print("[TEST] Database has " .. count .. " keywords")
    else
      print("[TEST] Failed to get database")
    end
  else
    print("[TEST] Failed to load store module: " .. tostring(store))
  end

  vim.notify("Test complete - check :messages", vim.log.levels.INFO)
end

return M
