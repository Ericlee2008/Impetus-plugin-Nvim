local M = {}

function M.log_path()
  return vim.fn.getcwd() .. "/impetus_nvim.log"
end

function M.append(operation, details)
  local log_path = M.log_path()
  local buf_name = vim.fn.expand("%:p")
  local lines = {
    "=== " .. tostring(operation) .. " " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===",
    "File: " .. (buf_name ~= "" and buf_name or "(unsaved)"),
  }
  for _, item in ipairs(details or {}) do
    lines[#lines + 1] = item
  end
  lines[#lines + 1] = ""
  local f = io.open(log_path, "a")
  if f then
    for _, l in ipairs(lines) do
      f:write(l .. "\n")
    end
    f:close()
  end
  return log_path
end

return M
