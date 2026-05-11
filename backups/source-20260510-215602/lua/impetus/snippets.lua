local store = require("impetus.store")

local M = {}

local function to_snippet_body(rows)
  local body = {}
  local cursor = 1
  for _, row in ipairs(rows or {}) do
    local vars = {}
    for _, p in ipairs(row) do
      vars[#vars + 1] = "${" .. cursor .. ":" .. p .. "}"
      cursor = cursor + 1
    end
    body[#body + 1] = table.concat(vars, ", ")
  end
  return body
end

function M.export_vscode_json(path)
  local db = store.get_db()
  local snippets = {}
  for keyword, entry in pairs(db) do
    local body = { keyword }
    local lines = to_snippet_body(entry.signature_rows)
    for _, line in ipairs(lines) do
      body[#body + 1] = line
    end
    snippets[keyword] = {
      prefix = { keyword, keyword:gsub("^%*", ""):lower() },
      body = body,
      description = "Auto-generated from commands.help",
    }
  end
  local encoded = vim.json.encode(snippets)
  vim.fn.writefile({ encoded }, path)
end

return M
