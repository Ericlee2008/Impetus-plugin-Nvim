local side_help = require("impetus.side_help")
local info = require("impetus.info")
local template = require("impetus.template")
local analysis = require("impetus.analysis")
local store = require("impetus.store")
local schema = require("impetus.schema")

local M = {}
local nav_cache = {}
local collect_keyword_ranges
local collect_control_ranges
local ensure_fold_ui_state
local is_boundary_line
local get_lines
local fold_hl_ns = vim.api.nvim_create_namespace("ImpetusFoldLine")

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_number_prefix(line)
  return (line:gsub("^%s*%d+%.%s*", ""))
end

local function parse_keyword(line)
  local normalized = trim(strip_number_prefix(line or ""))
  return normalized:match("^(%*[%w_%-]+)")
end

local function is_control_directive_line(line)
  local normalized = trim(strip_number_prefix(line or ""))
  if normalized:match("^~if%f[%A]") then
    return true
  end
  if normalized:match("^~else_if%f[%A]") then
    return true
  end
  if normalized:match("^~else%f[%A]") then
    return true
  end
  if normalized:match("^~end_if%f[%A]") then
    return true
  end
  if normalized:match("^~repeat%f[%A]") then
    return true
  end
  if normalized:match("^~end_repeat%f[%A]") then
    return true
  end
  if normalized:match("^~convert_from_") then
    return true
  end
  if normalized:match("^~end_convert%f[%A]") then
    return true
  end
  return false
end

local function directive_kind(line)
  local normalized = trim(strip_number_prefix(line or ""))
  if normalized:match("^~if%f[%A]") then
    return "if_start"
  end
  if normalized:match("^~else_if%f[%A]") then
    return "if_mid"
  end
  if normalized:match("^~else%f[%A]") then
    return "if_mid"
  end
  if normalized:match("^~end_if%f[%A]") then
    return "if_end"
  end
  if normalized:match("^~repeat%f[%A]") then
    return "repeat_start"
  end
  if normalized:match("^~end_repeat%f[%A]") then
    return "repeat_end"
  end
  if normalized:match("^~convert_from_") then
    return "convert_start"
  end
  if normalized:match("^~end_convert%f[%A]") then
    return "convert_end"
  end
  return nil
end

local function matching_start_row_for_end(lines, row, end_kind, start_kind)
  local depth = 0
  for r = row - 1, 1, -1 do
    local k = directive_kind(lines[r] or "")
    if k == end_kind then
      depth = depth + 1
    elseif k == start_kind then
      if depth == 0 then
        return r
      end
      depth = depth - 1
    end
  end
  return nil
end

local function matching_end_row_for_start(lines, row, start_kind, end_kind)
  local depth = 0
  for r = row + 1, #lines do
    local k = directive_kind(lines[r] or "")
    if k == start_kind then
      depth = depth + 1
    elseif k == end_kind then
      if depth == 0 then
        return r
      end
      depth = depth - 1
    end
  end
  return nil
end

local function directive_block_range(lines, row)
  local k = directive_kind(lines[row] or "")
  if not k then
    return nil, nil
  end

  -- if-family: always fold the full if-group from matching ~if to ~end_if,
  -- even when cursor is on ~else_if / ~else / ~end_if.
  if k == "if_start" then
    local e = matching_end_row_for_start(lines, row, "if_start", "if_end")
    return e and row or nil, e
  end
  if k == "if_mid" or k == "if_end" then
    local s = matching_start_row_for_end(lines, row, "if_end", "if_start")
    if not s then
      return nil, nil
    end
    local e = matching_end_row_for_start(lines, s, "if_start", "if_end")
    return s, e
  end

  if k == "repeat_start" then
    local e = matching_end_row_for_start(lines, row, "repeat_start", "repeat_end")
    return e and row or nil, e
  end
  if k == "repeat_end" then
    local s = matching_start_row_for_end(lines, row, "repeat_end", "repeat_start")
    return s, s and row or nil
  end

  if k == "convert_start" then
    local e = matching_end_row_for_start(lines, row, "convert_start", "convert_end")
    return e and row or nil, e
  end
  if k == "convert_end" then
    local s = matching_start_row_for_end(lines, row, "convert_end", "convert_start")
    return s, s and row or nil
  end

  return nil, nil
end

local function fold_toggle_at_anchor(anchor_row, force)
  if not anchor_row or anchor_row < 1 then
    return false
  end
  vim.api.nvim_win_set_cursor(0, { anchor_row, 0 })
  local closed = vim.fn.foldclosed(anchor_row) ~= -1
  if force == "close" then
    if not closed then
      pcall(vim.cmd, "silent! normal! zc")
    end
    return true
  end
  if force == "open" then
    if closed then
      pcall(vim.cmd, "silent! normal! zo")
    end
    return true
  end
  if closed then
    -- Expand closed fold under cursor.
    pcall(vim.cmd, "silent! normal! zo")
    pcall(vim.cmd, "silent! normal! zO")
  else
    -- Collapse open fold under cursor.
    pcall(vim.cmd, "silent! normal! zc")
  end
  -- Final safety toggle only if state did not change.
  local after = vim.fn.foldclosed(anchor_row) ~= -1
  if after == closed then
    pcall(vim.cmd, "silent! normal! zA")
  end
  return true
end

local function ensure_single_toggle_state()
  if type(vim.b.impetus_single_toggle_state) ~= "table" then
    vim.b.impetus_single_toggle_state = {
      kw = {},
      ctrl = {},
    }
  end
  vim.b.impetus_single_toggle_state.kw = vim.b.impetus_single_toggle_state.kw or {}
  vim.b.impetus_single_toggle_state.ctrl = vim.b.impetus_single_toggle_state.ctrl or {}
  return vim.b.impetus_single_toggle_state
end

local function range_toggle_key(s, e)
  return tostring(s) .. ":" .. tostring(e)
end

local function ensure_manual_fold_state()
  if type(vim.b.impetus_manual_fold_state) ~= "table" then
    vim.b.impetus_manual_fold_state = {
      kw_all_closed = false,
      ctrl_all_closed = false,
      kw_closed = {},
      ctrl_closed = {},
    }
  end
  local st = vim.b.impetus_manual_fold_state
  st.kw_closed = st.kw_closed or {}
  st.ctrl_closed = st.ctrl_closed or {}
  return st
end

local function ensure_manual_fold_mode()
  vim.wo.foldmethod = "manual"
  vim.wo.foldenable = true
  vim.wo.foldlevel = 99
end

local function close_manual_range(s, e)
  if not s or not e or e <= s then
    return false, "invalid-range"
  end
  vim.api.nvim_win_set_cursor(0, { s, 0 })
  local ok_fold, err_fold = pcall(vim.api.nvim_cmd, {
    cmd = "fold",
    range = { s, e },
    mods = { silent = true, emsg_silent = true },
  }, {})
  local ok_close, err_close = pcall(vim.api.nvim_cmd, {
    cmd = "normal",
    args = { "zc" },
    mods = { silent = true, emsg_silent = true },
  }, {})
  if not ok_fold then
    return false, "fold:" .. tostring(err_fold)
  end
  if not ok_close then
    return false, "zc:" .. tostring(err_close)
  end
  return vim.fn.foldclosed(s) ~= -1, "ok"
end

local function open_manual_range(s, e)
  if not s or not e or e <= s then
    return false, "invalid-range"
  end
  vim.api.nvim_win_set_cursor(0, { s, 0 })
  local ok_zo, err_zo = pcall(vim.api.nvim_cmd, {
    cmd = "normal",
    args = { "zo" },
    mods = { silent = true, emsg_silent = true },
  }, {})
  local ok_zO, err_zO = pcall(vim.api.nvim_cmd, {
    cmd = "normal",
    args = { "zO" },
    mods = { silent = true, emsg_silent = true },
  }, {})
  if not ok_zo then
    return false, "zo:" .. tostring(err_zo)
  end
  if not ok_zO then
    return false, "zO:" .. tostring(err_zO)
  end
  return vim.fn.foldclosed(s) == -1, "ok"
end

local function rebuild_manual_from_state(lines)
  local st = ensure_manual_fold_state()
  ensure_manual_fold_mode()
  pcall(vim.cmd, "silent! normal! zE")

  local ctrl_ranges = collect_control_ranges(lines)
  for _, r in ipairs(ctrl_ranges) do
    local key = range_toggle_key(r.s, r.e)
    local closed = st.ctrl_all_closed
    if st.ctrl_closed[key] ~= nil then
      closed = st.ctrl_closed[key] == true
    end
    if closed then
      close_manual_range(r.s, r.e)
    end
  end

  local kw_ranges = collect_keyword_ranges(lines)
  for _, r in ipairs(kw_ranges) do
    local key = range_toggle_key(r.s, r.e)
    local closed = st.kw_all_closed
    if st.kw_closed[key] ~= nil then
      closed = st.kw_closed[key] == true
    end
    if closed then
      close_manual_range(r.s, r.e)
    end
  end
end

local function set_range_closed(anchor_row, start_row, end_row, want_closed)
  vim.api.nvim_win_set_cursor(0, { anchor_row, 0 })
  if want_closed then
    pcall(vim.cmd, "silent! normal! zc")
    if vim.fn.foldclosed(anchor_row) == -1 and start_row and end_row and end_row > start_row then
      pcall(vim.cmd, string.format("silent! %d,%dfold", start_row, end_row))
      pcall(vim.cmd, string.format("silent! %d,%dfoldclose!", start_row, end_row))
    end
  else
    pcall(vim.cmd, "silent! normal! zo")
    pcall(vim.cmd, "silent! normal! zO")
    if vim.fn.foldclosed(anchor_row) ~= -1 and start_row and end_row and end_row > start_row then
      pcall(vim.cmd, string.format("silent! %d,%dfoldopen!", start_row, end_row))
    end
  end
  return vim.fn.foldclosed(anchor_row) ~= -1
end

local function range_key(s, e)
  return tostring(s) .. ":" .. tostring(e)
end

local function ensure_fold_state()
  if type(vim.b.impetus_fold_state) ~= "table" then
    vim.b.impetus_fold_state = {
      kw_all = false,
      ctrl_all = false,
      kw_overrides = {},
      ctrl_overrides = {},
    }
  end
  local st = vim.b.impetus_fold_state
  st.kw_overrides = st.kw_overrides or {}
  st.ctrl_overrides = st.ctrl_overrides or {}
  return st
end

local function clear_all_manual_folds()
  pcall(vim.cmd, "setlocal foldmethod=manual")
  pcall(vim.cmd, "setlocal foldenable")
  pcall(vim.cmd, "setlocal foldlevel=99")
  pcall(vim.cmd, "silent! normal! zE")
end

local function range_is_closed(st_all, overrides, s, e)
  local k = range_key(s, e)
  local v = overrides[k]
  if v == nil then
    return st_all
  end
  return v == true
end

local function create_closed_fold(s, e)
  if not s or not e or e <= s then
    return
  end
  pcall(vim.cmd, string.format("silent! %d,%dfold", s, e))
  vim.api.nvim_win_set_cursor(0, { s, 0 })
  pcall(vim.cmd, "silent! normal! zc")
end

local function rebuild_manual_folds(lines)
  local st = ensure_fold_state()
  clear_all_manual_folds()

  local kw_ranges = collect_keyword_ranges(lines)
  local ctrl_ranges = collect_control_ranges(lines)

  for _, r in ipairs(ctrl_ranges) do
    if range_is_closed(st.ctrl_all, st.ctrl_overrides, r.s, r.e) then
      create_closed_fold(r.s, r.e)
    end
  end
  for _, r in ipairs(kw_ranges) do
    if range_is_closed(st.kw_all, st.kw_overrides, r.s, r.e) then
      create_closed_fold(r.s, r.e)
    end
  end
end

local function set_override(overrides, all_flag, s, e, want_closed)
  local k = range_key(s, e)
  if want_closed == all_flag then
    overrides[k] = nil
  else
    overrides[k] = want_closed
  end
end

local function jump_to_matching_directive()
  local buf = vim.api.nvim_get_current_buf()
  local lines = get_lines(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local kind = directive_kind(lines[row] or "")
  if not kind then
    vim.notify("Cursor is not on a control directive", vim.log.levels.INFO)
    return false
  end

  local function jump(target_row)
    vim.api.nvim_win_set_cursor(0, { target_row, 0 })
    vim.cmd("normal! zz")
    return true
  end

  -- if/else_if/else/end_if family
  if kind == "if_end" then
    local depth = 0
    for r = row - 1, 1, -1 do
      local k = directive_kind(lines[r] or "")
      if k == "if_end" then
        depth = depth + 1
      elseif k == "if_start" then
        if depth == 0 then
          return jump(r)
        end
        depth = depth - 1
      end
    end
    vim.notify("No matching ~if found", vim.log.levels.WARN)
    return false
  end
  if kind == "if_start" or kind == "if_mid" then
    local depth = 0
    for r = row + 1, #lines do
      local k = directive_kind(lines[r] or "")
      if k == "if_start" then
        depth = depth + 1
      elseif k == "if_end" then
        if depth == 0 then
          return jump(r)
        end
        depth = depth - 1
      end
    end
    vim.notify("No matching ~end_if found", vim.log.levels.WARN)
    return false
  end

  -- repeat family
  if kind == "repeat_end" then
    local depth = 0
    for r = row - 1, 1, -1 do
      local k = directive_kind(lines[r] or "")
      if k == "repeat_end" then
        depth = depth + 1
      elseif k == "repeat_start" then
        if depth == 0 then
          return jump(r)
        end
        depth = depth - 1
      end
    end
    vim.notify("No matching ~repeat found", vim.log.levels.WARN)
    return false
  end
  if kind == "repeat_start" then
    local depth = 0
    for r = row + 1, #lines do
      local k = directive_kind(lines[r] or "")
      if k == "repeat_start" then
        depth = depth + 1
      elseif k == "repeat_end" then
        if depth == 0 then
          return jump(r)
        end
        depth = depth - 1
      end
    end
    vim.notify("No matching ~end_repeat found", vim.log.levels.WARN)
    return false
  end

  -- convert family
  if kind == "convert_end" then
    local depth = 0
    for r = row - 1, 1, -1 do
      local k = directive_kind(lines[r] or "")
      if k == "convert_end" then
        depth = depth + 1
      elseif k == "convert_start" then
        if depth == 0 then
          return jump(r)
        end
        depth = depth - 1
      end
    end
    vim.notify("No matching ~convert_from_* found", vim.log.levels.WARN)
    return false
  end
  if kind == "convert_start" then
    local depth = 0
    for r = row + 1, #lines do
      local k = directive_kind(lines[r] or "")
      if k == "convert_start" then
        depth = depth + 1
      elseif k == "convert_end" then
        if depth == 0 then
          return jump(r)
        end
        depth = depth - 1
      end
    end
    vim.notify("No matching ~end_convert found", vim.log.levels.WARN)
    return false
  end
  return false
end

local function check_directive_pairs()
  local buf = vim.api.nvim_get_current_buf()
  local lines = get_lines(buf)
  local stack = {}
  local problems = {}

  local function push(kind, row)
    stack[#stack + 1] = { kind = kind, row = row }
  end
  local function pop_expect(start_kind, end_kind, row)
    local top = stack[#stack]
    if not top or top.kind ~= start_kind then
      problems[#problems + 1] = string.format("Line %d: unexpected %s", row, end_kind)
      return
    end
    stack[#stack] = nil
  end

  for i, line in ipairs(lines) do
    local k = directive_kind(line)
    if k == "if_start" then
      push("if_start", i)
    elseif k == "if_end" then
      pop_expect("if_start", "~end_if", i)
    elseif k == "repeat_start" then
      push("repeat_start", i)
    elseif k == "repeat_end" then
      pop_expect("repeat_start", "~end_repeat", i)
    elseif k == "convert_start" then
      push("convert_start", i)
    elseif k == "convert_end" then
      pop_expect("convert_start", "~end_convert", i)
    end
  end

  for _, it in ipairs(stack) do
    local missing = (it.kind == "if_start" and "~end_if")
      or (it.kind == "repeat_start" and "~end_repeat")
      or "~end_convert"
    problems[#problems + 1] = string.format("Line %d: missing %s", it.row, missing)
  end

  if #problems == 0 then
    vim.notify("Directive pairs check passed", vim.log.levels.INFO)
    return true
  end

  vim.notify(table.concat(problems, "\n"), vim.log.levels.WARN)
  return false
end

local function parse_commented_keyword(line)
  local raw = line or ""
  local normalized = trim(strip_number_prefix(raw))
  local mark, rest = normalized:match("^([#$])%s*(.*)$")
  if not mark then
    return nil
  end
  local kw = (rest or ""):match("^(%*[%w_%-]+)")
  return kw
end

local function is_commented_line(line)
  local t = trim(strip_number_prefix(line or ""))
  local c = t:sub(1, 1)
  return c == "#" or c == "$"
end

local function parse_any_keyword(line)
  local kw = parse_keyword(line)
  if kw then
    return kw, "active"
  end
  kw = parse_commented_keyword(line)
  if kw then
    return kw, "commented"
  end
  return nil, nil
end

local function uncomment_one_level(line)
  local l = line or ""
  l = l:gsub("^%s*#%s?", "", 1)
  l = l:gsub("^%s*%$%s?", "", 1)
  return l
end

get_lines = function(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function find_block(buf, row)
  local lines = get_lines(buf)
  local start_row, keyword
  for r = row, 1, -1 do
    if is_control_directive_line(lines[r] or "") then
      return nil
    end
    local kw = parse_keyword(lines[r] or "")
    if kw then
      start_row = r
      keyword = kw
      break
    end
  end
  if not start_row then
    return nil
  end
  local end_row = #lines
  for r = start_row + 1, #lines do
    if is_boundary_line(lines[r] or "") then
      end_row = r - 1
      break
    end
  end
  return { start_row = start_row, end_row = end_row, keyword = keyword }
end

local function find_edit_block(buf, row)
  local lines = get_lines(buf)
  local cur = lines[row] or ""
  if is_control_directive_line(cur) then
    local s, e = directive_block_range(lines, row)
    if s and e and e >= s then
      return {
        start_row = s,
        end_row = e,
        kind = "control",
        keyword = directive_kind(lines[s] or ""),
      }
    end
    return nil
  end
  local b = find_block(buf, row)
  if not b then
    return nil
  end
  b.kind = "keyword"
  return b
end

local function find_any_block(buf, row)
  local lines = get_lines(buf)
  local start_row, keyword, kind
  for r = row, 1, -1 do
    local raw = lines[r] or ""
    local uncommented = uncomment_one_level(raw)
    if is_control_directive_line(raw) or is_control_directive_line(uncommented) then
      return nil
    end
    local kw, k = parse_any_keyword(lines[r] or "")
    if kw then
      start_row = r
      keyword = kw
      kind = k
      break
    end
  end
  if not start_row then
    return nil
  end
  local end_row = #lines
  for r = start_row + 1, #lines do
    local raw = lines[r] or ""
    local uncommented = uncomment_one_level(raw)
    local kw = parse_any_keyword(raw)
    if kw or is_control_directive_line(raw) or is_control_directive_line(uncommented) then
      end_row = r - 1
      break
    end
  end
  return { start_row = start_row, end_row = end_row, keyword = keyword, kind = kind }
end

local function find_commented_block_near(buf, row)
  local lines = get_lines(buf)
  local best_row = nil
  local best_dist = math.huge
  for i, line in ipairs(lines) do
    if parse_commented_keyword(line or "") then
      local d = math.abs(i - row)
      if d < best_dist or (d == best_dist and (not best_row or i < best_row)) then
        best_dist = d
        best_row = i
      end
    end
  end
  if not best_row then
    return nil
  end
  return find_any_block(buf, best_row)
end

local function is_preview_meta(preview)
  local t = trim(strip_number_prefix(preview or ""))
  if t == "" then
    return true
  end
  local c = t:sub(1, 1)
  if c == "#" or c == "$" or c == "*" or c == "~" then
    return true
  end
  if t:match("^%-+$") then
    return true
  end
  if t:match("^%-%-%-.*%-%-%-$") then
    return true
  end
  if t == "Variable         Description" then
    return true
  end
  return false
end

local function csv_field_count(line)
  local t = trim(strip_number_prefix(line or ""))
  if t == "" then
    return 0
  end
  local n = 1
  for _ in t:gmatch(",") do
    n = n + 1
  end
  return n
end

local function split_csv_keep_empty(line)
  local out = {}
  local t = trim(strip_number_prefix(line or ""))
  local s = t .. ","
  for part in s:gmatch("(.-),") do
    out[#out + 1] = trim(part)
  end
  return out
end

local function looks_like_tail_repeat(preview, tail_fields)
  local pt = trim(strip_number_prefix(preview or ""))
  if pt == "" or is_preview_meta(preview) then
    return false
  end
  if tail_fields and tail_fields > 0 then
    return csv_field_count(pt) == tail_fields
  end
  return true
end

local function is_set_member_token(token)
  local t = trim(token or "")
  if t == "" then
    return false
  end
  if t:match("^%-?%d+%.?0*$") then
    return true
  end
  if t:match("^%-?%d+%.?0*%.%.%-?%d+%.?0*$") then
    return true
  end
  if t:match("^%-?%%[%a_][%w_]*$") then
    return true
  end
  if t:match("^%-?%[%s*%%[%a_][%w_]*%s*%]$") then
    return true
  end
  if t:match("^%-?%%[%a_][%w_]*%.%.%-?%%[%a_][%w_]*$") then
    return true
  end
  if t:match("^%-?%[%s*%%[%a_][%w_]*%s*%]%.%.%-?%[%s*%%[%a_][%w_]*%s*%]$") then
    return true
  end
  return false
end

local function looks_like_set_member_row(preview)
  local pt = trim(strip_number_prefix(preview or ""))
  if pt == "" or is_preview_meta(preview) then
    return false
  end
  local fields = split_csv_keep_empty(pt)
  if #fields < 1 or #fields > 8 then
    return false
  end
  for _, f in ipairs(fields) do
    if not is_set_member_token(f) then
      return false
    end
  end
  return true
end

local function is_valid_uncomment_candidate(keyword, row_index, preview, entry)
  local pt = trim(strip_number_prefix(preview or ""))
  if pt == "" or is_preview_meta(preview) then
    return false
  end
  local kw = (keyword or ""):upper()
  if kw == "*PARAMETER" or kw == "*PARAMETER_DEFAULT" then
    if not pt:match("=") then
      return false
    end
  end
  return schema.is_valid_data_line(keyword, row_index, pt, entry)
end

local function collect_rows_for_smart_uncomment(lines, block)
  local rows = {}
  if not block then
    return rows
  end
  rows[#rows + 1] = block.start_row

  local entry = store.get_keyword(block.keyword or "")
  local expected_data = 0
  local has_title = false
  if entry then
    expected_data = #(entry.signature_rows or {})
    has_title = entry.has_optional_title == true
  end
  local meta = schema.keyword_meta(block.keyword, entry)
  local mode = meta.repeat_mode or "schema"
  local tail_fields = meta.tail_repeat_fields
  local tail_from_row = meta.tail_repeat_from_row or expected_data
  local group_rows = meta.repeat_group_rows or expected_data
  local group_optional_first_row = meta.group_optional_first_row == true
  local optional_rows = meta.optional_rows or {}

  local r = block.start_row + 1
  local got_title = false
  local got_data = 0
  local pair_expect_title = has_title
  local group_expect_title = has_title
  local group_data = 0

  local function consume_preview(preview, abs_row, add_row)
    local pt = trim(strip_number_prefix(preview))
    if pt == "" or is_preview_meta(preview) then
      return false
    end

    local function accept()
      if add_row then
        rows[#rows + 1] = abs_row
      end
      return true
    end

    if mode == "full_repeat_all" then
      return accept()
    elseif mode == "full_repeat" then
      if is_valid_uncomment_candidate(block.keyword, got_data + 1, preview, entry) then
        got_data = got_data + 1
        return accept()
      end
      return false
    elseif mode == "paired_repeat" then
      if pair_expect_title then
        if pt:match('^".*"$') then
          pair_expect_title = false
          return accept()
        end
        pair_expect_title = false
      end
      if is_valid_uncomment_candidate(block.keyword, got_data + 1, preview, entry) then
        got_data = got_data + 1
        pair_expect_title = has_title
        return accept()
      end
      return false
    elseif mode == "group_repeat" then
      if group_expect_title then
        if pt:match('^".*"$') then
          group_expect_title = false
          return accept()
        end
        group_expect_title = false
      end
      if is_valid_uncomment_candidate(block.keyword, group_data + 1, preview, entry) then
        got_data = got_data + 1
        group_data = group_data + 1
        if group_data >= group_rows then
          group_data = 0
          group_expect_title = has_title
        end
        return accept()
      elseif group_optional_first_row and group_data == 0
        and is_valid_uncomment_candidate(block.keyword, 2, preview, entry)
      then
        got_data = got_data + 1
        group_data = 0
        group_expect_title = has_title
        return accept()
      end
      return false
    elseif has_title and not got_title and pt:match('^".*"$') then
      got_title = true
      return accept()
    elseif expected_data <= 0 then
      if not is_preview_meta(preview) then
        return accept()
      end
      return false
    elseif (block.keyword or ""):upper():match("^%*SET_") and got_data >= 1 and looks_like_set_member_row(preview) then
      got_data = math.max(got_data, tail_from_row)
      return accept()
    elseif optional_rows[got_data + 1] == true
      and (got_data + 1) < expected_data
      and is_valid_uncomment_candidate(block.keyword, got_data + 2, preview, entry)
    then
      got_data = got_data + 2
      return accept()
    elseif mode == "tail_repeat" and got_data >= tail_from_row then
      local is_set_family = (block.keyword or ""):upper():match("^%*SET_") ~= nil
      local tail_ok
      if is_set_family then
        tail_ok = is_valid_uncomment_candidate(block.keyword, tail_from_row, preview, entry)
          or is_valid_uncomment_candidate(block.keyword, tail_from_row + 1, preview, entry)
      else
        tail_ok = looks_like_tail_repeat(preview, tail_fields)
          and is_valid_uncomment_candidate(block.keyword, tail_from_row + 1, preview, entry)
      end
      if tail_ok then
        return accept()
      end
      return false
    elseif got_data < expected_data and is_valid_uncomment_candidate(block.keyword, got_data + 1, preview, entry) then
      got_data = got_data + 1
      return accept()
    end

    return false
  end

  while r <= block.end_row do
    local raw = lines[r] or ""
    if parse_commented_keyword(raw) and r ~= block.start_row then
      break
    end

    if is_commented_line(raw) then
      local ok = consume_preview(uncomment_one_level(raw), r, true)
      if not ok and got_data > 0 and mode ~= "tail_repeat" then
        break
      end
    else
      consume_preview(raw, r, false)
    end
    r = r + 1
  end

  return rows
end

local function collect_rows_for_partial_block_uncomment(lines, block)
  local rows = {}
  if not block then
    return rows
  end

  local entry = store.get_keyword(block.keyword or "")
  local expected_data = entry and #(entry.signature_rows or {}) or 0
  if expected_data <= 1 then
    return rows
  end
  local has_title = entry and entry.has_optional_title == true or false
  local saw_data = false
  local saw_title = false

  for r = block.start_row + 1, block.end_row do
    local raw = lines[r] or ""
    local preview = uncomment_one_level(raw)
    local pt = trim(strip_number_prefix(preview))
    if pt ~= "" and not is_preview_meta(preview) then
      if not is_commented_line(raw) then
        if has_title and not saw_title and pt:match('^".*"$') then
          saw_title = true
        else
          saw_data = true
        end
      elseif saw_data then
        local ok = false
        local max_idx = math.max(1, expected_data + 1)
        for idx = 1, max_idx do
          if schema.is_valid_data_line(block.keyword, idx, pt, entry) then
            ok = true
            break
          end
        end
        if ok then
          rows[#rows + 1] = r
        end
      end
    end
  end

  return rows
end

local function build_uncomment_row_set(lines, block)
  local row_set = {}
  if not block then
    return row_set
  end

  local block_entry = store.get_keyword(block.keyword or "")
  local block_expected = block_entry and #(block_entry.signature_rows or {}) or 0
  local meta = schema.keyword_meta(block.keyword, block_entry)

  for _, rr in ipairs(collect_rows_for_smart_uncomment(lines, block)) do
    row_set[rr] = true
  end
  for _, rr in ipairs(collect_rows_for_partial_block_uncomment(lines, block)) do
    row_set[rr] = true
  end

  if block_expected == 1 and (meta.repeat_mode or "schema") == "schema" then
    for rr = block.start_row + 1, block.end_row do
      local raw = lines[rr] or ""
      if is_commented_line(raw) then
        local preview = uncomment_one_level(raw)
        local pt = trim(strip_number_prefix(preview))
        if pt ~= "" and not is_preview_meta(preview) then
          row_set[rr] = true
          break
        end
      end
    end
  end

  return row_set
end

local function can_strictly_recover_line(keyword, preview, entry)
  local pt = trim(strip_number_prefix(preview or ""))
  if pt == "" or is_preview_meta(preview) then
    return false
  end
  if entry and entry.has_optional_title == true and pt:match('^".*"$') then
    return true
  end
  local max_idx = math.max(1, (entry and #(entry.signature_rows or {}) or 0) + 1)
  for idx = 1, max_idx do
    if schema.is_valid_data_line(keyword, idx, pt, entry) then
      return true
    end
  end
  return false
end

local function debug_collect_rows_for_smart_uncomment(lines, block)
  local out = {}
  if not block then
    out[#out + 1] = "block=nil"
    return out
  end

  out[#out + 1] = string.format("keyword=%s start=%d end=%d", tostring(block.keyword), block.start_row or -1, block.end_row or -1)

  local entry = store.get_keyword(block.keyword or "")
  local expected_data = 0
  local has_title = false
  if entry then
    expected_data = #(entry.signature_rows or {})
    has_title = entry.has_optional_title == true
  end
  local meta = schema.keyword_meta(block.keyword, entry)
  local mode = meta.repeat_mode or "schema"
  local tail_fields = meta.tail_repeat_fields
  local tail_from_row = meta.tail_repeat_from_row or expected_data
  out[#out + 1] = string.format("mode=%s expected_data=%d has_title=%s tail_from_row=%s tail_fields=%s",
    tostring(mode), expected_data, tostring(has_title), tostring(tail_from_row), tostring(tail_fields))

  local rows = {}
  rows[#rows + 1] = block.start_row
  local r = block.start_row + 1
  local got_title = false
  local got_data = 0

  while r <= block.end_row do
    local raw = lines[r] or ""
    local preview = uncomment_one_level(raw)
    local pt = trim(strip_number_prefix(preview))
    local is_comment = is_commented_line(raw)
    local valid_cur = is_valid_uncomment_candidate(block.keyword, got_data + 1, preview, entry)
    local valid_tail = is_valid_uncomment_candidate(block.keyword, tail_from_row, preview, entry)
    local valid_tail_next = is_valid_uncomment_candidate(block.keyword, tail_from_row + 1, preview, entry)
    out[#out + 1] = string.format(
      "r=%d raw=%q pt=%q comment=%s got_title=%s got_data=%d valid(cur=%d)=%s valid(tail=%d)=%s valid(tail+1=%d)=%s",
      r, raw, pt, tostring(is_comment), tostring(got_title), got_data, got_data + 1, tostring(valid_cur),
      tail_from_row, tostring(valid_tail), tail_from_row + 1, tostring(valid_tail_next)
    )

    if is_comment then
      if has_title and not got_title and pt:match('^".*"$') then
        rows[#rows + 1] = r
        got_title = true
        out[#out + 1] = "  -> accept title"
      elseif got_data < expected_data and valid_cur then
        rows[#rows + 1] = r
        got_data = got_data + 1
        out[#out + 1] = "  -> accept schema row"
      elseif mode == "tail_repeat" and got_data >= tail_from_row and (valid_tail or valid_tail_next) then
        rows[#rows + 1] = r
        out[#out + 1] = "  -> accept tail row"
      else
        out[#out + 1] = "  -> reject"
      end
    end
    r = r + 1
  end

  out[#out + 1] = "rows=" .. vim.inspect(rows)
  out[#out + 1] = "final_row_set=" .. vim.inspect(build_uncomment_row_set(lines, block))
  return out
end

local function goto_next_keyword_after(buf, row)
  local lines = get_lines(buf)
  for r = math.max(1, row + 1), #lines do
    if parse_keyword(lines[r] or "") then
      vim.api.nvim_win_set_cursor(0, { r, 0 })
      return
    end
  end
  local here = math.min(row, #lines)
  vim.api.nvim_win_set_cursor(0, { math.max(1, here), 0 })
end

local function goto_next_block_after(buf, row)
  local lines = get_lines(buf)
  for r = math.max(1, row + 1), #lines do
    local line = lines[r] or ""
    if parse_keyword(line) or is_control_directive_line(line) then
      vim.api.nvim_win_set_cursor(0, { r, 0 })
      return
    end
  end
  local here = math.min(math.max(1, row), #lines)
  vim.api.nvim_win_set_cursor(0, { math.max(1, here), 0 })
end

local function fast_keyword_check(line)
  -- Fast path: check if line starts with * (after trimming/prefix)
  local normalized = trim(strip_number_prefix(line or ""))
  if normalized:byte(1) ~= 42 then -- 42 = '*'
    return false
  end
  -- Slow path: full parse only if starts with *
  return parse_keyword(line)
end

local function rebuild_keyword_index_async(buf, tick)
  -- Rebuild index in background (non-blocking)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local rows = {}
    local lines = get_lines(buf)
    for i, line in ipairs(lines) do
      if fast_keyword_check(line) then
        rows[#rows + 1] = i
      end
    end
    nav_cache[buf] = { tick = tick, rows = rows, lines = lines }
  end)
end

local function ensure_keyword_index(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local cache = nav_cache[buf]

  -- ✓ Cache hit: fast return (no I/O at all)
  if cache and cache.tick == tick and cache.rows then
    return cache.rows
  end

  -- Cache miss: return stale data immediately, rebuild async
  if cache and cache.rows then
    rebuild_keyword_index_async(buf, tick)
    return cache.rows
  end

  -- First time: build synchronously but with fast keyword check
  local rows = {}
  local lines = get_lines(buf)
  for i, line in ipairs(lines) do
    if fast_keyword_check(line) then
      rows[#rows + 1] = i
    end
  end
  nav_cache[buf] = { tick = tick, rows = rows, lines = lines }
  return rows
end

local function next_row(rows, row)
  local lo, hi = 1, #rows
  local ans = nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if rows[mid] > row then
      ans = rows[mid]
      hi = mid - 1
    else
      lo = mid + 1
    end
  end
  return ans
end

local function prev_row(rows, row)
  local lo, hi = 1, #rows
  local ans = nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if rows[mid] < row then
      ans = rows[mid]
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return ans
end

local function set_cursor(row, col0)
  vim.api.nvim_win_set_cursor(0, { row, col0 or 0 })
end

local function has_help_window_open()
  -- Check if help window already exists
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      if vim.b[b].impetus_help_buffer == 1 then
        return true
      end
    end
  end
  return false
end

local function fast_nav_to(row)
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  -- ⚡ Move cursor immediately (non-blocking)
  pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })

  -- Only update help/info if they're already open (don't force create)
  local help_exists = has_help_window_open()
  local config = require("impetus.config").get()

  if help_exists or config.side_help_track then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win) then
        if help_exists then
          pcall(side_help.render, buf, win)
        end
        pcall(info.sync_active)
      end
    end)
  end
end

local function refresh_fold_render(mode)
  -- Recompute folds + force full redraw to avoid stale first-screen artifacts
  -- after zM/zR on some terminals.
  if mode == "single" then
    local view = vim.fn.winsaveview()
    pcall(vim.fn.winrestview, view)
    pcall(vim.cmd, "redraw!")
    pcall(vim.cmd, "normal! <C-l>")
    pcall(vim.api.nvim__redraw, { valid = true, flush = true })
    vim.schedule(function()
      pcall(vim.cmd, "redraw!")
      pcall(vim.api.nvim__redraw, { valid = true, flush = true })
    end)
    return
  end
  local view = vim.fn.winsaveview()
  if mode == "close_all" then
    pcall(vim.cmd, "silent! normal! zM")
  elseif mode == "open_all" then
    pcall(vim.cmd, "silent! normal! zR")
  end
  pcall(vim.cmd, "silent! normal! zX")
  pcall(vim.fn.winrestview, view)
  pcall(vim.cmd, "redraw!")
  pcall(vim.cmd, "normal! <C-l>")
  pcall(vim.api.nvim__redraw, { valid = true, flush = true })
  vim.schedule(function()
    if mode == "close_all" then
      pcall(vim.cmd, "silent! normal! zM")
    elseif mode == "open_all" then
      pcall(vim.cmd, "silent! normal! zR")
    end
    pcall(vim.cmd, "silent! normal! zX")
    pcall(vim.cmd, "redraw!")
    pcall(vim.api.nvim__redraw, { valid = true, flush = true })
  end)
end

local function refresh_fold_line_highlights(lines)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(buf, fold_hl_ns, 0, -1)
  local st = ensure_fold_ui_state()

  for _, r in ipairs(collect_keyword_ranges(lines)) do
    if st.kw_closed[range_toggle_key(r.s, r.e)] == true and vim.fn.foldclosed(r.s) ~= -1 then
      vim.api.nvim_buf_set_extmark(buf, fold_hl_ns, r.s - 1, 0, {
        line_hl_group = "impetusFoldedKeywordLine",
        priority = 120,
      })
    end
  end

  for _, r in ipairs(collect_control_ranges(lines)) do
    if st.ctrl_closed[range_toggle_key(r.s, r.e)] == true and vim.fn.foldclosed(r.s) ~= -1 then
      vim.api.nvim_buf_set_extmark(buf, fold_hl_ns, r.s - 1, 0, {
        line_hl_group = "impetusFoldedControlLine",
        priority = 130,
      })
    end
  end
end

local function is_comment_or_empty(line)
  local t = trim(line or "")
  if t == "" then
    return true
  end
  local c = t:sub(1, 1)
  return c == "#" or c == "$"
end

local function parse_include_path_from_line(line)
  local t = trim(strip_number_prefix(line or ""))
  if t == "" then
    return nil
  end
  t = trim((t:gsub("%s[#$].*$", "")))
  if t == "" then
    return nil
  end
  local q = t:match('"(.-)"')
  if q and q ~= "" then
    return trim(q)
  end
  -- Strong Windows absolute path handling (avoid truncating to drive letter).
  if t:match("^[A-Za-z]:") then
    local p = trim((t:match("^([A-Za-z]:[^,]*)") or t))
    if p ~= "" then
      return p
    end
  end
  local wabs = t:match("([A-Za-z]:[\\/][^,%s]+%.[A-Za-z0-9_]+)")
  if wabs and wabs ~= "" then
    return trim(wabs)
  end
  local relf = t:match("([%w%._%-%/\\]+%.[A-Za-z0-9_]+)")
  if relf and relf ~= "" then
    return trim(relf)
  end
  local first = trim((t:match("^([^,]+)") or ""))
  if first ~= "" then
    return first
  end
  return nil
end

function M.toggle_comment_block()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local col0 = cursor[2]
  local line = vim.api.nvim_get_current_line()
  local full_lines = get_lines(buf)

  local block = nil
  local do_uncomment = false
  if is_commented_line(line) then
    local commented_block = find_any_block(buf, row) or find_commented_block_near(buf, row)
    if commented_block and commented_block.kind == "commented" then
      block = commented_block
      do_uncomment = true
    else
      local active_block = find_block(buf, row)
      if active_block then
        block = active_block
        local block_entry = store.get_keyword(block.keyword or "")
        local probe = build_uncomment_row_set(full_lines, block)
        local preview = uncomment_one_level(line)
        if can_strictly_recover_line(block.keyword, preview, block_entry) then
          do_uncomment = true
        else
          for rr, _ in pairs(probe) do
            if rr ~= block.start_row and is_commented_line(full_lines[rr] or "") then
              local rp = uncomment_one_level(full_lines[rr] or "")
              if can_strictly_recover_line(block.keyword, rp, block_entry) then
                do_uncomment = true
                break
              end
            end
          end
        end
      else
        block = commented_block
        do_uncomment = block and block.kind == "commented" or false
      end
    end
  else
    block = find_any_block(buf, row) or find_block(buf, row)
    if block then
      local block_entry = store.get_keyword(block.keyword or "")
      local probe = build_uncomment_row_set(full_lines, block)
      for rr, _ in pairs(probe) do
        if is_commented_line(full_lines[rr] or "") then
          local preview = uncomment_one_level(full_lines[rr] or "")
          if rr == block.start_row or can_strictly_recover_line(block.keyword, preview, block_entry) then
            do_uncomment = true
            break
          end
        end
      end
    end
  end

  if not block then
    return
  end

  vim.g.impetus_last_comment_debug = {
    keyword = block.keyword,
    start_row = block.start_row,
    end_row = block.end_row,
    do_uncomment = do_uncomment,
    row = row,
  }

  local lines = vim.api.nvim_buf_get_lines(buf, block.start_row - 1, block.end_row, false)
  if do_uncomment then
    local block_entry = store.get_keyword(block.keyword or "")
    local block_expected = block_entry and #(block_entry.signature_rows or {}) or 0
    local row_set = build_uncomment_row_set(full_lines, block)
    vim.g.impetus_last_comment_debug.final_row_set = vim.deepcopy(row_set)
    for pass = 1, 2 do
      local changed_this_pass = false
      for i, l in ipairs(lines) do
        local abs_row = block.start_row + i - 1
        if row_set[abs_row] and trim(l) ~= "" and is_commented_line(l) then
          local preview = uncomment_one_level(l)
          if abs_row == block.start_row or can_strictly_recover_line(block.keyword, preview, block_entry) then
            lines[i] = preview
            full_lines[abs_row] = lines[i]
            changed_this_pass = true
          end
        end
      end
      if pass == 1 and changed_this_pass then
        row_set = build_uncomment_row_set(full_lines, block)
      else
        break
      end
    end

    if (block.keyword or ""):upper() == "*UNIT_SYSTEM" then
      for i, l in ipairs(lines) do
        local abs_row = block.start_row + i - 1
        if abs_row > block.start_row and is_commented_line(l) then
          local preview = uncomment_one_level(l)
          local pt = trim(strip_number_prefix(preview))
          if pt ~= "" and not is_preview_meta(preview) then
            lines[i] = preview
            full_lines[abs_row] = preview
            break
          end
        end
      end
    end

    -- Final deterministic cleanup for mixed blocks: once earlier data rows in the
    -- same block are already active, allow any remaining commented row that
    -- clearly validates as a later data line to be released in the same command.
    local saw_active_data = false
    for i, l in ipairs(lines) do
      local abs_row = block.start_row + i - 1
      local preview = uncomment_one_level(l)
      local pt = trim(strip_number_prefix(preview))
      if not is_preview_meta(preview) and pt ~= "" then
        if not is_commented_line(l) then
          saw_active_data = true
        elseif saw_active_data then
          local ok = false
          local max_idx = math.max(1, block_expected + 1)
          for idx = 1, max_idx do
            if schema.is_valid_data_line(block.keyword, idx, pt, block_entry) then
              ok = true
              break
            end
          end
          if ok then
            lines[i] = preview
            full_lines[abs_row] = preview
          end
        end
      end
    end

    vim.api.nvim_buf_set_lines(buf, block.start_row - 1, block.end_row, false, lines)
    set_cursor(row, col0)
    return
  end

  for i, l in ipairs(lines) do
    if trim(l) == "" then
      lines[i] = "#"
    elseif not l:match("^%s*[#$]") then
      lines[i] = "# " .. l
    end
  end
  vim.api.nvim_buf_set_lines(buf, block.start_row - 1, block.end_row, false, lines)
  set_cursor(row, col0)
end

function M.delete_block()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local b = find_edit_block(buf, row)
  if not b then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, b.start_row - 1, b.end_row, false)
  local reg_type = "V"
  pcall(vim.fn.setreg, '"', lines, reg_type)
  pcall(vim.fn.setreg, "0", lines, reg_type)
  pcall(vim.fn.setreg, "1", lines, reg_type)
  if tostring(vim.o.clipboard or ""):find("unnamedplus", 1, true) then
    pcall(vim.fn.setreg, "+", lines, reg_type)
  end
  if tostring(vim.o.clipboard or ""):find("unnamed", 1, true) then
    pcall(vim.fn.setreg, "*", lines, reg_type)
  end
  vim.api.nvim_buf_set_lines(buf, b.start_row - 1, b.end_row, false, {})
  goto_next_block_after(buf, b.start_row - 1)
end

function M.copy_block_below()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local b = find_edit_block(buf, row)
  if not b then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, b.start_row - 1, b.end_row, false)
  local reg_type = "V"
  pcall(vim.fn.setreg, '"', lines, reg_type)
  pcall(vim.fn.setreg, "0", lines, reg_type)
  if tostring(vim.o.clipboard or ""):find("unnamedplus", 1, true) then
    pcall(vim.fn.setreg, "+", lines, reg_type)
  end
  if tostring(vim.o.clipboard or ""):find("unnamed", 1, true) then
    pcall(vim.fn.setreg, "*", lines, reg_type)
  end
end

function M.move_block_down()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local b = find_block(buf, row)
  if not b then
    return
  end
  local lines = get_lines(buf)
  local next_start = nil
  for r = b.end_row + 1, #lines do
    if parse_keyword(lines[r] or "") then
      next_start = r
      break
    end
  end
  if not next_start then
    return
  end
  local next_end = #lines
  for r = next_start + 1, #lines do
    if parse_keyword(lines[r] or "") then
      next_end = r - 1
      break
    end
  end
  local block1 = vim.api.nvim_buf_get_lines(buf, b.start_row - 1, b.end_row, false)
  local block2 = vim.api.nvim_buf_get_lines(buf, next_start - 1, next_end, false)
  vim.api.nvim_buf_set_lines(buf, b.start_row - 1, next_end, false, vim.list_extend(block2, block1))
  set_cursor(next_end - #block1 + 1, 0)
end

function M.move_block_up()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local b = find_block(buf, row)
  if not b then
    return
  end
  local lines = get_lines(buf)
  local prev_start = nil
  local prev_end = nil
  for r = b.start_row - 1, 1, -1 do
    if parse_keyword(lines[r] or "") then
      prev_start = r
      break
    end
  end
  if not prev_start then
    return
  end
  prev_end = b.start_row - 1
  for r = prev_start + 1, b.start_row - 1 do
    if parse_keyword(lines[r] or "") then
      prev_end = r - 1
      break
    end
  end
  local block1 = vim.api.nvim_buf_get_lines(buf, prev_start - 1, prev_end, false)
  local block2 = vim.api.nvim_buf_get_lines(buf, b.start_row - 1, b.end_row, false)
  vim.api.nvim_buf_set_lines(buf, prev_start - 1, b.end_row, false, vim.list_extend(block2, block1))
  set_cursor(prev_start, 0)
end

function M.goto_next_keyword()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local rows = ensure_keyword_index(buf)
  if #rows == 0 then
    return
  end
  local target = next_row(rows, row) or rows[1]
  fast_nav_to(target)
end

function M.goto_prev_keyword()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local rows = ensure_keyword_index(buf)
  if #rows == 0 then
    return
  end
  local target = prev_row(rows, row) or rows[#rows]
  fast_nav_to(target)
end

is_boundary_line = function(line)
  return parse_keyword(line or "") ~= nil or is_control_directive_line(line or "")
end

local function keyword_bounds_from_start(lines, start_row)
  local s = start_row
  if not s or not parse_keyword(lines[s] or "") then
    return nil
  end
  local e = #lines
  for r = s + 1, #lines do
    if is_boundary_line(lines[r] or "") then
      e = r - 1
      break
    end
  end
  if e < s then
    e = s
  end
  return { s = s, e = e }
end

local function find_keyword_bounds_at_row(lines, row)
  local line = lines[row] or ""
  if is_control_directive_line(line) then
    return nil
  end

  local s = nil
  for r = row, 1, -1 do
    local l = lines[r] or ""
    if parse_keyword(l) then
      s = r
      break
    end
    if is_control_directive_line(l) then
      return nil
    end
  end
  if not s then
    return nil
  end
  return keyword_bounds_from_start(lines, s)
end

collect_keyword_ranges = function(lines)
  local ranges = {}
  for i = 1, #lines do
    if parse_keyword(lines[i] or "") then
      local b = keyword_bounds_from_start(lines, i)
      if b then
        ranges[#ranges + 1] = b
      end
    end
  end
  return ranges
end

collect_control_ranges = function(lines)
  local ranges = {}
  for i = 1, #lines do
    local k = directive_kind(lines[i] or "")
    if k == "if_start" or k == "repeat_start" or k == "convert_start" then
      local s, e = directive_block_range(lines, i)
      if s and e and e >= s then
        ranges[#ranges + 1] = { s = s, e = e }
      end
    end
  end
  return ranges
end

ensure_fold_ui_state = function()
  local st = vim.b.impetus_fold_ui_state
  if type(st) ~= "table" then
    st = {
      kw_closed = {},
      ctrl_closed = {},
    }
    vim.b.impetus_fold_ui_state = st
  end
  st.kw_closed = st.kw_closed or {}
  st.ctrl_closed = st.ctrl_closed or {}
  return st
end

local function save_fold_ui_state(st)
  vim.b.impetus_fold_ui_state = st
end

local function rebuild_all_manual_folds(lines)
  local st = ensure_fold_ui_state()
  ensure_manual_fold_mode()
  pcall(vim.cmd, "silent! normal! zE")

  local ranges = {}
  for _, r in ipairs(collect_control_ranges(lines)) do
    if st.ctrl_closed[range_toggle_key(r.s, r.e)] == true then
      ranges[#ranges + 1] = r
    end
  end
  for _, r in ipairs(collect_keyword_ranges(lines)) do
    if st.kw_closed[range_toggle_key(r.s, r.e)] == true then
      ranges[#ranges + 1] = r
    end
  end

  table.sort(ranges, function(a, b)
    if a.s == b.s then
      return a.e > b.e
    end
    return a.s < b.s
  end)

  for _, r in ipairs(ranges) do
    if r.e > r.s then
      close_manual_range(r.s, r.e)
    end
  end

  if #ranges > 0 then
    local first = ranges[1]
    vim.notify(
      string.format(
        "rebuild first=%d:%d foldclosed(%d)=%s total=%d",
        first.s, first.e, first.s, tostring(vim.fn.foldclosed(first.s)), #ranges
      ),
      vim.log.levels.INFO,
      { title = "Impetus Fold Rebuild" }
    )
  end
  refresh_fold_line_highlights(lines)
end

local function reapply_keyword_manual_folds(lines)
  local st = ensure_fold_ui_state()
  ensure_manual_fold_mode()
  local ranges = collect_keyword_ranges(lines)
  for _, r in ipairs(ranges) do
    if st.kw_closed[range_toggle_key(r.s, r.e)] == true and r.e > r.s then
      close_manual_range(r.s, r.e)
    end
  end
end

function M.toggle_all_keyword_folds()
  local lines = get_lines(vim.api.nvim_get_current_buf())
  local st = ensure_fold_ui_state()
  local ranges = collect_keyword_ranges(lines)
  if #ranges == 0 then
    return
  end
  local all_closed = true
  for _, r in ipairs(ranges) do
    if st.kw_closed[range_toggle_key(r.s, r.e)] ~= true then
      all_closed = false
      break
    end
  end
  local close_now = not all_closed
  ensure_manual_fold_mode()
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  for _, r in ipairs(ranges) do
    local key = range_toggle_key(r.s, r.e)
    if close_now then
      st.kw_closed[key] = true
    else
      st.kw_closed[key] = nil
    end
  end
  save_fold_ui_state(st)
  rebuild_all_manual_folds(lines)
  vim.api.nvim_win_set_cursor(0, { row, col0 })
  vim.notify(
    string.format("kw-all %s count=%d", close_now and "close" or "open", #ranges),
    vim.log.levels.INFO,
    { title = "Impetus Fold Toggle" }
  )
  refresh_fold_render("single")
  refresh_fold_line_highlights(lines)
end

function M.toggle_all_control_folds()
  local lines = get_lines(vim.api.nvim_get_current_buf())
  local st = ensure_fold_ui_state()
  local ranges = collect_control_ranges(lines)
  if #ranges == 0 then
    return
  end
  local all_closed = true
  for _, r in ipairs(ranges) do
    if st.ctrl_closed[range_toggle_key(r.s, r.e)] ~= true then
      all_closed = false
      break
    end
  end
  local close_now = not all_closed
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  for _, r in ipairs(ranges) do
    local key = range_toggle_key(r.s, r.e)
    if close_now then
      st.ctrl_closed[key] = true
    else
      st.ctrl_closed[key] = nil
    end
  end
  save_fold_ui_state(st)
  rebuild_all_manual_folds(lines)
  vim.api.nvim_win_set_cursor(0, { row, col0 })
  vim.notify(
    string.format("ctrl-all %s count=%d", close_now and "close" or "open", #ranges),
    vim.log.levels.INFO,
    { title = "Impetus Fold Toggle" }
  )
  refresh_fold_render("single")
  refresh_fold_line_highlights(lines)
end

function M.toggle_fold_here()
  return M.toggle_keyword_fold_here()
end

function M.toggle_keyword_fold_here()
  local buf = vim.api.nvim_get_current_buf()
  local lines = get_lines(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local cur_line = lines[row] or ""
  if is_control_directive_line(cur_line) then
    vim.notify("Use ,T for control statements", vim.log.levels.INFO)
    return
  end
  local b = find_keyword_bounds_at_row(lines, row)
  if not b then
    return
  end
  local st = ensure_fold_ui_state()
  local key = range_toggle_key(b.s, b.e)
  local action = nil
  if st.kw_closed[key] == true then
    st.kw_closed[key] = nil
    action = "open"
  else
    st.kw_closed[key] = true
    action = "close"
  end
  save_fold_ui_state(st)
  rebuild_all_manual_folds(lines)
  vim.notify(
    string.format(
      "kw %s %d:%d -> ok=%s why=%s foldclosed(%d)=%s",
      action, b.s, b.e, "true", "rebuild", b.s, tostring(vim.fn.foldclosed(b.s))
    ),
    vim.log.levels.INFO,
    { title = "Impetus Fold Toggle" }
  )
  vim.api.nvim_win_set_cursor(0, { b.s, 0 })
  refresh_fold_render("single")
  refresh_fold_line_highlights(lines)
end

function M.toggle_control_fold_here()
  local buf = vim.api.nvim_get_current_buf()
  local lines = get_lines(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local cur_line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  if not is_control_directive_line(cur_line) then
    vim.notify("Cursor is not on a control statement", vim.log.levels.INFO)
    return
  end
  local s, e = directive_block_range(lines, row)
  if not s or not e or e <= s then
    vim.notify("Cannot resolve control block range at cursor", vim.log.levels.WARN)
    return
  end
  local st = ensure_fold_ui_state()
  local key = range_toggle_key(s, e)
  local action = nil
  if st.ctrl_closed[key] == true then
    st.ctrl_closed[key] = nil
    action = "open"
  else
    st.ctrl_closed[key] = true
    action = "close"
  end
  save_fold_ui_state(st)
  rebuild_all_manual_folds(lines)
  vim.notify(
    string.format(
      "ctrl %s %d:%d -> ok=%s why=%s foldclosed(%d)=%s",
      action, s, e, "true", "rebuild", s, tostring(vim.fn.foldclosed(s))
    ),
    vim.log.levels.INFO,
    { title = "Impetus Fold Toggle" }
  )
  vim.api.nvim_win_set_cursor(0, { s, 0 })
  refresh_fold_render("single")
  refresh_fold_line_highlights(lines)
end

function M.show_ref_completion()
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local ctx = analysis.current_context(bufnr, row, col0)
  if not ctx or not ctx.param_name then
    vim.notify("No parameter context under cursor", vim.log.levels.INFO)
    return
  end

  local entry = store.get_db()[ctx.keyword or ""]
  local desc = entry and entry.descriptions and entry.descriptions[ctx.param_name] or ""
  local options = {}
  for _, id in ipairs(analysis.suggest_object_values(bufnr, ctx, "")) do
    options[#options + 1] = id
  end
  if desc and desc ~= "" then
    local opt = desc:match("%[options:%s*(.-)%]")
    if opt then
      for x in opt:gmatch("[^,%s]+") do
        if x ~= "" then
          options[#options + 1] = x
        end
      end
    end
  end

  local seen = {}
  local uniq = {}
  for _, x in ipairs(options) do
    if x ~= "" and not seen[x] then
      seen[x] = true
      uniq[#uniq + 1] = x
    end
  end
  if #uniq == 0 then
    vim.notify("No suggested values for " .. ctx.param_name, vim.log.levels.INFO)
    return
  end

  local line = vim.api.nvim_get_current_line()
  local fields = {}
  local start_pos = 1
  local i = 1
  local function emit(stop_pos)
    local part = line:sub(start_pos, stop_pos)
    fields[#fields + 1] = {
      text = trim(part),
      start_col1 = start_pos,
      end_col1 = stop_pos,
    }
  end
  while i <= #line do
    local ch = line:sub(i, i)
    if ch == "," then
      emit(i - 1)
      start_pos = i + 1
    end
    i = i + 1
  end
  emit(#line)
  local f = ctx.field_idx and fields[ctx.field_idx] or nil

  if not f then
    vim.notify("No editable field under cursor", vim.log.levels.INFO)
    return
  end

  local s = math.max(1, f.start_col1)
  local e = math.max(s - 1, f.end_col1)
  local new_line = line:sub(1, s - 1) .. line:sub(e + 1)
  vim.api.nvim_set_current_line(new_line)
  set_cursor(row, s - 1)

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local mode = vim.api.nvim_get_mode().mode
    if mode ~= "i" and mode ~= "ic" and mode ~= "ix" then
      vim.cmd("startinsert")
    end
    pcall(vim.fn.complete, s, uniq)
  end)
end

function M.open_include_under_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local block = find_block(buf, row)
  if not block then
    return
  end
  local kw = (block.keyword or ""):upper()
  if kw ~= "*INCLUDE" and kw ~= "*SCRIPT_PYTHON" then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, block.start_row - 1, block.end_row, false)
  local f = nil
  local function looks_invalid_include(v)
    local x = trim(v or "")
    if x == "" then
      return true
    end
    if x:match("^[A-Za-z]$") then
      return true
    end
    return false
  end

  if #lines > 0 then
    local header = lines[1] or ""
    local inline = trim(strip_number_prefix(header)):match("^%*[%w_%-]+%s*,?%s*(.+)$")
    f = parse_include_path_from_line(inline or "")
    if looks_invalid_include(f) then
      f = nil
    end
  end
  if not f then
    for i = 2, #lines do
      local l = lines[i] or ""
      if not is_comment_or_empty(l) then
        local cand = parse_include_path_from_line(l)
        if cand and not looks_invalid_include(cand) then
          f = cand
          break
        end
      end
    end
  end

  if not f or f == "" then
    return
  end
  local src_win = vim.api.nvim_get_current_win()
  if src_win and vim.api.nvim_win_is_valid(src_win) then
    local src_buf = vim.api.nvim_win_get_buf(src_win)
    local c = vim.api.nvim_win_get_cursor(src_win)
    vim.g.impetus_main_return = {
      win = src_win,
      buf = src_buf,
      row = c[1],
      col = c[2],
    }
  end
  local base = vim.fn.expand("%:p:h")
  local full = nil
  local f_norm = (f or ""):gsub("\\", "/")
  if f_norm:match("^[A-Za-z]:/") or f_norm:match("^/") then
    full = vim.fn.fnamemodify(f_norm, ":p")
  else
    full = vim.fn.fnamemodify(base .. "/" .. f_norm, ":p")
  end
  if vim.fn.filereadable(full) == 1 then
    vim.g.impetus_opening_child = 1
    vim.cmd("leftabove vsplit")
    local w = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(w) then
      vim.w[w].impetus_child_window = 1
      vim.g.impetus_last_child_win = w
    end
    vim.cmd("edit " .. vim.fn.fnameescape(full))
    local b = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(b) then
      vim.b[b].impetus_child_buffer = 1
    end
    vim.schedule(function()
      vim.g.impetus_opening_child = 0
    end)
  else
    vim.notify("Include file not found: " .. f, vim.log.levels.WARN)
  end
end

function M.open_in_gui()
  local exe = vim.g.impetus_gui_exe
  if not exe or exe == "" then
    vim.notify("Set g:impetus_gui_exe first", vim.log.levels.WARN)
    return
  end
  local file = vim.fn.expand("%:p")
  if file == "" then
    return
  end
  if vim.fn.has("win32") == 1 then
    vim.fn.jobstart({ "cmd", "/c", "start", "", exe, file }, { detach = true })
  else
    vim.fn.jobstart({ exe, file }, { detach = true })
  end
end

function M.color_match_blocks()
  local buf = vim.api.nvim_get_current_buf()
  local lines = get_lines(buf)

  -- Clear old highlights and virtual text
  local ns_id = vim.api.nvim_create_namespace("impetus_match_pairs")
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  -- Define matched block colors (foreground only)
  local colors = {
    "#ff6b6b",  -- Red
    "#4ecdc4",  -- Cyan
    "#ffe66d",  -- Yellow
    "#a8e6cf",  -- Green
    "#c7ceea",  -- Purple
    "#ff9999",  -- Light red
  }

  -- Create highlight group for each color (virtual text label color)
  for i, color in ipairs(colors) do
    local hl_group = "impetusMatchPair" .. i
    vim.api.nvim_set_hl(0, hl_group, {
      fg = color,
      bold = true,
    })
  end

  local pair_count = 0
  local processed = {}

  -- Process if blocks
  for row = 1, #lines do
    if processed[row] then goto continue end

    local k = directive_kind(lines[row] or "")
    if k == "if_start" then
      local end_row = matching_end_row_for_start(lines, row, "if_start", "if_end")
      if end_row then
        pair_count = pair_count + 1
        local color_idx = ((pair_count - 1) % #colors) + 1
        local hl_group = "impetusMatchPair" .. color_idx
        local label = string.format("[Pair %d]", pair_count)

        -- Only add virtual text labels on start and end lines
        vim.api.nvim_buf_set_extmark(buf, ns_id, row - 1, -1, {
          virt_text = { { label, hl_group } },
          virt_text_pos = "eol",
        })
        vim.api.nvim_buf_set_extmark(buf, ns_id, end_row - 1, -1, {
          virt_text = { { label, hl_group } },
          virt_text_pos = "eol",
        })

        processed[row] = true
        processed[end_row] = true
      end
    end

    ::continue::
  end

  -- Process repeat blocks
  for row = 1, #lines do
    if processed[row] then goto continue_repeat end

    local k = directive_kind(lines[row] or "")
    if k == "repeat_start" then
      local end_row = matching_end_row_for_start(lines, row, "repeat_start", "repeat_end")
      if end_row then
        pair_count = pair_count + 1
        local color_idx = ((pair_count - 1) % #colors) + 1
        local hl_group = "impetusMatchPair" .. color_idx
        local label = string.format("[Pair %d]", pair_count)

        vim.api.nvim_buf_set_extmark(buf, ns_id, row - 1, -1, {
          virt_text = { { label, hl_group } },
          virt_text_pos = "eol",
        })
        vim.api.nvim_buf_set_extmark(buf, ns_id, end_row - 1, -1, {
          virt_text = { { label, hl_group } },
          virt_text_pos = "eol",
        })

        processed[row] = true
        processed[end_row] = true
      end
    end

    ::continue_repeat::
  end

  -- Process convert blocks
  for row = 1, #lines do
    if processed[row] then goto continue_convert end

    local k = directive_kind(lines[row] or "")
    if k == "convert_start" then
      local end_row = matching_end_row_for_start(lines, row, "convert_start", "convert_end")
      if end_row then
        pair_count = pair_count + 1
        local color_idx = ((pair_count - 1) % #colors) + 1
        local hl_group = "impetusMatchPair" .. color_idx
        local label = string.format("[Pair %d]", pair_count)

        vim.api.nvim_buf_set_extmark(buf, ns_id, row - 1, -1, {
          virt_text = { { label, hl_group } },
          virt_text_pos = "eol",
        })
        vim.api.nvim_buf_set_extmark(buf, ns_id, end_row - 1, -1, {
          virt_text = { { label, hl_group } },
          virt_text_pos = "eol",
        })

        processed[row] = true
        processed[end_row] = true
      end
    end

    ::continue_convert::
  end

  vim.notify(
    string.format("✅ Marked %d control block pair(s)", pair_count),
    vim.log.levels.INFO,
    { title = "Match Block Marking" }
  )
end

function M.check_blocks()
  local buf = vim.api.nvim_get_current_buf()
  local lines = get_lines(buf)

  -- Track stacks for three block types
  local if_stack = {}
  local repeat_stack = {}
  local convert_stack = {}

  local issues = {}

  for row = 1, #lines do
    local k = directive_kind(lines[row] or "")

    if not k then
      goto continue
    end

    if k == "if_start" then
      table.insert(if_stack, row)
    elseif k == "if_end" then
      if #if_stack == 0 then
        table.insert(issues, {
          line = row,
          type = "extra_end",
          block = "if",
          message = string.format("Line %d: Extra ~end_if (no matching ~if)", row)
        })
      else
        table.remove(if_stack)
      end
    elseif k == "if_mid" then
      if #if_stack == 0 then
        table.insert(issues, {
          line = row,
          type = "unmatched",
          block = "if",
          message = string.format("Line %d: ~else_if/~else without matching ~if", row)
        })
      end

    elseif k == "repeat_start" then
      table.insert(repeat_stack, row)
    elseif k == "repeat_end" then
      if #repeat_stack == 0 then
        table.insert(issues, {
          line = row,
          type = "extra_end",
          block = "repeat",
          message = string.format("Line %d: Extra ~end_repeat (no matching ~repeat)", row)
        })
      else
        table.remove(repeat_stack)
      end

    elseif k == "convert_start" then
      table.insert(convert_stack, row)
    elseif k == "convert_end" then
      if #convert_stack == 0 then
        table.insert(issues, {
          line = row,
          type = "extra_end",
          block = "convert",
          message = string.format("Line %d: Extra ~end_convert (no matching ~convert_from)", row)
        })
      else
        table.remove(convert_stack)
      end
    end

    ::continue::
  end

  -- Add unclosed blocks
  for _, line in ipairs(if_stack) do
    table.insert(issues, {
      line = line,
      type = "unclosed",
      block = "if",
      message = string.format("Line %d: ~if without matching ~end_if", line)
    })
  end

  for _, line in ipairs(repeat_stack) do
    table.insert(issues, {
      line = line,
      type = "unclosed",
      block = "repeat",
      message = string.format("Line %d: ~repeat without matching ~end_repeat", line)
    })
  end

  for _, line in ipairs(convert_stack) do
    table.insert(issues, {
      line = line,
      type = "unclosed",
      block = "convert",
      message = string.format("Line %d: ~convert_from without matching ~end_convert", line)
    })
  end

  -- Display results
  if #issues == 0 then
    vim.notify("✅ All control blocks are properly matched!", vim.log.levels.INFO, { title = "Block Check" })
  else
    -- Sort by line number
    table.sort(issues, function(a, b) return a.line < b.line end)

    -- Build message
    local msg_lines = { "❌ Found " .. #issues .. " block matching issue(s):\n" }
    for _, issue in ipairs(issues) do
      table.insert(msg_lines, issue.message)
    end

    local full_msg = table.concat(msg_lines, "\n")
    vim.notify(full_msg, vim.log.levels.WARN, { title = "Block Check" })

    -- Jump to first issue
    if issues[1] then
      vim.api.nvim_win_set_cursor(0, { issues[1].line, 0 })
    end
  end
end

function M.jump_match_block()
  local buf = vim.api.nvim_get_current_buf()
  local lines = get_lines(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local cur_line = lines[row] or ""
  local k = directive_kind(cur_line)

  if not k then
    vim.notify("Not on a control directive (~if, ~repeat, ~convert_from, etc.)", vim.log.levels.INFO)
    return
  end

  local target_row = nil

  -- Process if-family (if/else_if/else/end_if)
  if k == "if_start" then
    target_row = matching_end_row_for_start(lines, row, "if_start", "if_end")
  elseif k == "if_end" then
    target_row = matching_start_row_for_end(lines, row, "if_end", "if_start")
  elseif k == "if_mid" then
    -- Jump from else_if/else to end_if
    target_row = matching_end_row_for_start(lines, row, "if_start", "if_end")
  -- Process repeat-family (repeat/end_repeat)
  elseif k == "repeat_start" then
    target_row = matching_end_row_for_start(lines, row, "repeat_start", "repeat_end")
  elseif k == "repeat_end" then
    target_row = matching_start_row_for_end(lines, row, "repeat_end", "repeat_start")
  -- Process convert-family (convert_from/end_convert)
  elseif k == "convert_start" then
    target_row = matching_end_row_for_start(lines, row, "convert_start", "convert_end")
  elseif k == "convert_end" then
    target_row = matching_start_row_for_end(lines, row, "convert_end", "convert_start")
  end

  if target_row then
    vim.api.nvim_win_set_cursor(0, { target_row, 0 })

    -- Auto-show match coloring
    M.color_match_blocks()

    vim.notify(
      string.format("Jumped from line %d to line %d", row, target_row),
      vim.log.levels.INFO,
      { title = "Impetus Match Block" }
    )
  else
    vim.notify("No matching block found", vim.log.levels.WARN)
  end
end

function M.toggle_all_folds()
  -- Fold all keyword blocks and control blocks at the same time
  M.toggle_all_keyword_folds()
  M.toggle_all_control_folds()
end

function M.toggle_help()
  local state = side_help.get_debug_state and side_help.get_debug_state() or nil
  if state and state.win and vim.api.nvim_win_is_valid(state.win) then
    side_help.close_for_current()
    return
  end
  side_help.open_for_current()
end

return M
