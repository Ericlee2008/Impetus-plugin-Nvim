-- param_selector_simple.lua
-- Simplified parameter value selector using interactive menu

local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_csv(line)
  local out = {}
  local col_start = 0
  for part in line:gmatch("[^,]+") do
    local trimmed = trim(part)
    if trimmed ~= "" or part ~= "" then
      table.insert(out, {
        value = trimmed,
        start_col = col_start,
        end_col = col_start + #part - 1,
      })
    end
    col_start = col_start + #part + 1
  end
  return out
end

local function extract_options_from_description(desc)
  if not desc or desc == "" then
    return nil
  end

  local options_str = nil

  -- Format 1: [options: N, NS, P, PS, ...]
  options_str = desc:match("%[options:%s*([^%]]+)%]")

  -- Format 2: options: A -> acceleration B -> ...
  if not options_str then
    options_str = desc:match("options:%s*(.+)$")
  end

  if not options_str then
    return nil
  end

  local options = {}

  -- Try to extract from "options: A -> acceleration B -> velocity" format
  for opt in options_str:gmatch("([A-Za-z0-9_]+)%s*->") do
    if opt ~= "" then
      table.insert(options, opt)
    end
  end

  -- If no "-> " format, try comma-separated format
  if #options == 0 then
    for opt in options_str:gmatch("[^,%s]+") do
      if opt ~= "" and opt ~= "->" then
        table.insert(options, opt)
      end
    end
  end

  return #options > 0 and options or nil
end

local function is_parameter_data_line(line)
  -- A line is a parameter data line if it contains commas and is not a comment/separator
  if not line or line == "" then return false end
  if line:match("^%s*#") then return false end  -- Comment
  if line:match("^%-%-%-%-") then return false end  -- Separator
  if line:match("^%*") then return false end  -- Keyword
  if line == '"Optional title"' then return false end
  if line:match("^Variable%s+Description") then return false end
  -- It's a parameter line if it has content (typically with commas)
  return true
end

local function get_cursor_context()
  local buf = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Find keyword row by searching backwards
  local keyword_row = nil
  for i = row, 0, -1 do
    local line = lines[i + 1] or ""
    if line:match("^%*[%u%d_%-]+") then
      keyword_row = i
      break
    end
  end

  if not keyword_row then
    return nil
  end

  local keyword_line = lines[keyword_row + 1] or ""
  local keyword = keyword_line:match("^(%*[%u%d_%-]+)")
  if not keyword then
    return nil
  end

  local ok, db = pcall(require("impetus.store").get_db)
  if not ok or not db then
    return nil
  end

  local kw_entry = db[keyword]
  if not kw_entry then
    return nil
  end

  -- Check if current line is a parameter data line
  local current_line = lines[row + 1] or ""
  if not is_parameter_data_line(current_line) then
    return nil
  end

  local params_in_row = split_csv(current_line)
  if #params_in_row == 0 then
    return nil
  end

  local cursor_param = nil
  local param_idx_in_row = nil
  for idx, p in ipairs(params_in_row) do
    if col >= p.start_col and col <= p.end_col then
      cursor_param = p
      param_idx_in_row = idx
      break
    end
  end

  if not cursor_param or not param_idx_in_row then
    return nil
  end

  -- Use signature_rows to accurately map data rows to parameter indices
  local param_idx = nil
  local data_line_count = 0

  for check_row = keyword_row + 1, row do
    local check_line = lines[check_row + 1] or ""
    if is_parameter_data_line(check_line) then
      data_line_count = data_line_count + 1

      if check_row == row then
        -- Found the matching data line
        -- Calculate which parameter group this data line belongs to
        local param_count_before = 0
        if kw_entry.signature_rows then
          for sig_idx = 1, data_line_count - 1 do
            if kw_entry.signature_rows[sig_idx] then
              param_count_before = param_count_before + #kw_entry.signature_rows[sig_idx]
            end
          end
        end
        param_idx = param_count_before + param_idx_in_row
        break
      end
    end
  end

  if not param_idx or param_idx > #kw_entry.params or param_idx < 1 then
    return nil
  end

  local param_name = kw_entry.params[param_idx]
  if not param_name or param_name == "" then
    return nil
  end

  return {
    keyword = keyword,
    param_name = param_name,
    param_idx = param_idx,
    cursor_param = cursor_param,
    row = row,
    col = col,
  }
end

function M.show_param_selector()
  local buf = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local current_line = lines[row + 1] or ""

  print("=== 详细调试 ===")
  print("光标位置: Row=" .. row .. " Col=" .. col)
  print("当前行内容: " .. current_line)

  local context = get_cursor_context()
  if not context then
    print("get_cursor_context() 返回 nil")
    vim.notify("Not on a valid parameter", vim.log.levels.WARN)
    return
  end

  print("识别到的关键字: " .. context.keyword)
  print("识别到的参数名: " .. context.param_name)
  print("识别到的参数索引: " .. context.param_idx)

  -- Parse current line to show parameters
  local params_in_row = split_csv(current_line)
  print("当前行参数个数: " .. #params_in_row)
  for i, p in ipairs(params_in_row) do
    print("  参数 " .. i .. ": [" .. p.start_col .. "-" .. p.end_col .. "] = '" .. p.value .. "'")
  end

  local ok, db = pcall(require("impetus.store").get_db)
  if not ok or not db then
    vim.notify("Database not loaded", vim.log.levels.WARN)
    return
  end

  local kw_entry = db[context.keyword]
  if not kw_entry or not kw_entry.details then
    vim.notify("Keyword not found", vim.log.levels.WARN)
    return
  end

  local param_detail = kw_entry.details[context.param_idx]
  if not param_detail or not param_detail.description then
    print("参数 " .. context.param_idx .. " 无描述")
    vim.notify("No parameter info: param_idx=" .. context.param_idx, vim.log.levels.INFO)
    return
  end

  print("参数描述: " .. param_detail.description)

  local options = extract_options_from_description(param_detail.description)
  if not options or #options == 0 then
    print("无法提取选项")
    vim.notify(context.keyword .. " " .. context.param_name .. " 无选项", vim.log.levels.INFO)
    return
  end

  print("提取的选项: " .. table.concat(options, ", "))
  local msg = context.keyword .. " " .. context.param_name .. " -> " .. table.concat(options, " | ")
  vim.notify(msg, vim.log.levels.INFO)
end

return M
