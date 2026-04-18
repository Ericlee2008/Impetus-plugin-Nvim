local store = require("impetus.store")
local analysis = require("impetus.analysis")

local M = {}

local ns = vim.api.nvim_create_namespace("impetus-lint")

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function count_csv_fields(line)
  local n = 0
  for _ in line:gmatch("[^,]+") do
    n = n + 1
  end
  return n
end

local function starts_with(s, p)
  return s:sub(1, #p) == p
end

function M.run(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local db = store.get_db()
  local diagnostics = {}

  local current_keyword = nil
  local expected_fields = nil
  local seen_data_line = false
  local if_stack = {}
  local repeat_stack = {}
  local convert_stack = {}
  local seen_unit_system = false
  local idx = analysis.build_buffer_index(bufnr)

  for i, raw in ipairs(lines) do
    local line = trim(raw)
    local keyword = line:match("^(%*[%u%d_%-]+)")
    if keyword then
      current_keyword = keyword
      seen_data_line = false
      expected_fields = nil
      local entry = db[keyword]
      if not entry then
        diagnostics[#diagnostics + 1] = {
          lnum = i - 1,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          message = "Unknown keyword in commands.help database: " .. keyword,
          source = "impetus",
        }
      elseif entry.signature_rows and entry.signature_rows[1] then
        expected_fields = #entry.signature_rows[1]
      end
      if keyword == "*UNIT_SYSTEM" then
        seen_unit_system = true
      end
    elseif starts_with(line:lower(), "~if") then
      if_stack[#if_stack + 1] = i
    elseif starts_with(line:lower(), "~else_if") then
      if #if_stack == 0 then
        diagnostics[#diagnostics + 1] = {
          lnum = i - 1,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          message = "~else_if without matching ~if",
          source = "impetus",
        }
      end
    elseif starts_with(line:lower(), "~else") then
      if #if_stack == 0 then
        diagnostics[#diagnostics + 1] = {
          lnum = i - 1,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          message = "~else without matching ~if",
          source = "impetus",
        }
      end
    elseif starts_with(line:lower(), "~end_if") then
      if #if_stack == 0 then
        diagnostics[#diagnostics + 1] = {
          lnum = i - 1,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          message = "~end_if without matching ~if",
          source = "impetus",
        }
      else
        table.remove(if_stack)
      end
    elseif starts_with(line:lower(), "~repeat") then
      repeat_stack[#repeat_stack + 1] = i
    elseif starts_with(line:lower(), "~end_repeat") then
      if #repeat_stack == 0 then
        diagnostics[#diagnostics + 1] = {
          lnum = i - 1,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          message = "~end_repeat without matching ~repeat",
          source = "impetus",
        }
      else
        table.remove(repeat_stack)
      end
    elseif starts_with(line:lower(), "~convert_from_") then
      convert_stack[#convert_stack + 1] = i
      if not seen_unit_system then
        diagnostics[#diagnostics + 1] = {
          lnum = i - 1,
          col = 0,
          severity = vim.diagnostic.severity.INFO,
          message = "Unit conversion used before *UNIT_SYSTEM is defined",
          source = "impetus",
        }
      end
    elseif starts_with(line:lower(), "~end_convert") then
      if #convert_stack == 0 then
        diagnostics[#diagnostics + 1] = {
          lnum = i - 1,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          message = "~end_convert without matching ~convert_from_",
          source = "impetus",
        }
      else
        table.remove(convert_stack)
      end
    elseif current_keyword and line ~= "" and line:sub(1, 1) ~= "#" and line:sub(1, 1) ~= "$" and line:sub(1, 1) ~= "~" then
      if not seen_data_line and expected_fields and expected_fields > 0 then
        seen_data_line = true
        local got = count_csv_fields(line)
        if got ~= expected_fields then
          diagnostics[#diagnostics + 1] = {
            lnum = i - 1,
            col = 0,
            severity = vim.diagnostic.severity.INFO,
            message = "Field count differs from first signature row, expected " .. expected_fields .. ", got " .. got,
            source = "impetus",
          }
        end
      end
    end
  end

  for _, ln in ipairs(if_stack) do
    diagnostics[#diagnostics + 1] = {
      lnum = ln - 1,
      col = 0,
      severity = vim.diagnostic.severity.WARN,
      message = "Unclosed ~if block",
      source = "impetus",
    }
  end
  for _, ln in ipairs(repeat_stack) do
    diagnostics[#diagnostics + 1] = {
      lnum = ln - 1,
      col = 0,
      severity = vim.diagnostic.severity.WARN,
      message = "Unclosed ~repeat block",
      source = "impetus",
    }
  end
  for _, ln in ipairs(convert_stack) do
    diagnostics[#diagnostics + 1] = {
      lnum = ln - 1,
      col = 0,
      severity = vim.diagnostic.severity.WARN,
      message = "Unclosed ~convert_from_ block",
      source = "impetus",
    }
  end

  for name, refs in pairs(idx.params.refs or {}) do
    if not idx.params.defs[name] or #idx.params.defs[name] == 0 then
      local first = refs[1]
      if first then
        diagnostics[#diagnostics + 1] = {
          lnum = (first.row or 1) - 1,
          col = first.col or 0,
          severity = vim.diagnostic.severity.INFO,
          message = "Parameter %" .. name .. " is referenced but not defined in this file",
          source = "impetus",
        }
      end
    end
  end

  vim.diagnostic.set(ns, bufnr, diagnostics, {})
  return diagnostics
end

return M
