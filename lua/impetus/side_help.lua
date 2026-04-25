local config = require("impetus.config")
local store = require("impetus.store")
local highlight = require("impetus.highlight")

local M = {}

local state = {
  pane = nil,
  ns_static = vim.api.nvim_create_namespace("ImpetusSideHelpStatic"),
  ns_active = vim.api.nvim_create_namespace("ImpetusSideHelpActive"),
  parse_cache = {},
  user_closed = true,
  suspend = false,
}

local function list_help_windows()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_buf_is_valid(b) and vim.b[b].impetus_help_buffer == 1 then
        out[#out + 1] = { win = w, buf = b }
      end
    end
  end
  return out
end

local find_main_window_candidate

local function resolve_primary_source(source_buf, source_win)
  local buf = source_buf
  local win = source_win
  local invalid = false
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    invalid = true
  else
    if vim.b[buf].impetus_help_buffer == 1 or vim.b[buf].impetus_info_buffer == 1 then
      invalid = true
    end
  end
  if win and vim.api.nvim_win_is_valid(win) then
    if vim.w[win].impetus_nav_window == 1 or vim.w[win].impetus_help_window == 1 then
      invalid = true
    end
  else
    invalid = true
  end
  if invalid then
    local w, b = find_main_window_candidate()
    if w and b then
      return b, w
    end
  end
  return buf, win
end

find_main_window_candidate = function()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_buf_is_valid(b) then
        if vim.b[b].impetus_help_buffer ~= 1 and vim.b[b].impetus_info_buffer ~= 1
          and vim.w[w].impetus_nav_window ~= 1 and vim.w[w].impetus_child_window ~= 1
        then
          return w, b
        end
      end
    end
  end
  return nil, nil
end

local function recover_existing_pane()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_buf_is_valid(b) and vim.b[b].impetus_help_buffer == 1 then
        local src_buf = vim.b[b].impetus_help_source
        if type(src_buf) ~= "number" or not vim.api.nvim_buf_is_valid(src_buf) then
          src_buf = nil
        end
        local main_win, main_buf = find_main_window_candidate()
        state.pane = {
          win = w,
          buf = b,
          source_buf = src_buf or main_buf,
          source_win = main_win,
          main_win = main_win,
          keyword = nil,
          param = nil,
        }
        return state.pane
      end
    end
  end
  return nil
end

local function ensure_help_syntax(help_buf)
  if not (help_buf and vim.api.nvim_buf_is_valid(help_buf)) then
    return
  end
  vim.api.nvim_buf_call(help_buf, function()
    vim.cmd("silent! syntax clear")
    vim.cmd("silent! unlet! b:current_syntax")
    vim.cmd("silent! runtime! syntax/impetus.vim")
  end)
  highlight.apply()
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_csv_outside_quotes(line)
  local out = {}
  local in_quotes = false
  local start_pos = 1
  local i = 1

  local function emit(end_pos)
    local seg = line:sub(start_pos, end_pos)
    out[#out + 1] = trim(seg)
  end

  while i <= #line do
    local ch = line:sub(i, i)
    if ch == '"' then
      in_quotes = not in_quotes
    elseif ch == "," and not in_quotes then
      emit(i - 1)
      start_pos = i + 1
    end
    i = i + 1
  end
  emit(#line)
  return out
end

local function strip_number_prefix(line)
  return (line:gsub("^%s*%d+%.%s*", ""))
end

local function normalize_name(s)
  local v = s or ""
  v = v:gsub("^%s*%d+%.%s*", "")
  v = v:gsub("^%[", ""):gsub("%]$", "")
  v = v:gsub("^%%", "")
  v = v:gsub("^#", "")
  v = trim(v)
  return v:lower()
end

local function parse_keyword(line)
  local normalized = trim(strip_number_prefix(line or ""))
  return normalized:match("^(%*[%w_%-]+)")
end

local function ensure_parse_cache(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local cache = state.parse_cache[buf]
  if cache and cache.tick == tick then
    return cache.lines, cache.keyword_rows
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local keyword_rows = {}
  for i, line in ipairs(lines) do
    if parse_keyword(line or "") then
      keyword_rows[#keyword_rows + 1] = i
    end
  end
  state.parse_cache[buf] = {
    tick = tick,
    lines = lines,
    keyword_rows = keyword_rows,
  }
  return lines, keyword_rows
end

local function is_optional_title_line(line)
  local normalized = trim(strip_number_prefix(line or ""))
  if normalized == '"Optional title"' or normalized == '"Optional title" ' then
    return true
  end
  -- In real .k files, title rows are often free text wrapped by quotes, e.g. "Liner".
  if normalized:match('^".*"$') then
    return true
  end
  return false
end

local function is_separator_or_meta(line)
  local normalized = trim(strip_number_prefix(line or ""))
  if normalized == "" then
    return true
  end
  if normalized:sub(1, 1) == "#" then
    return true
  end
  if normalized:sub(1, 1) == "$" then
    return true
  end
  if normalized == '"Optional title"' then
    return true
  end
  if normalized:match('^".*"$') then
    return true
  end
  if normalized == "Variable         Description" then
    return true
  end
  if normalized:match("^%-+$") then
    return true
  end
  if normalized:sub(1, 1) == "~" then
    return true
  end
  return false
end

local function find_keyword_block(lines, keyword_rows, row)
  if not keyword_rows or #keyword_rows == 0 then
    return nil
  end
  local lo, hi = 1, #keyword_rows
  local idx = nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local v = keyword_rows[mid]
    if v <= row then
      idx = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  if not idx then
    return nil
  end
  local start_row = keyword_rows[idx]
  local keyword = parse_keyword(lines[start_row] or "")
  if not keyword then
    return nil
  end
  local next_start = keyword_rows[idx + 1]
  local end_row = next_start and (next_start - 1) or #lines
  return { keyword = keyword, start_row = start_row, end_row = end_row }
end

local function collect_data_rows(lines, block)
  local rows = {}
  local saw_non_title = false
  for r = block.start_row + 1, block.end_row do
    local line = lines[r] or ""
    if not is_separator_or_meta(line) then
      if block.keyword == "*BC_MOTION" and not saw_non_title then
        local values = split_csv_outside_quotes(line)
        local first = trim(values[1] or "")
        if first ~= "" and not first:match('^".*"$') then
          saw_non_title = true
          if not (
            first:match("^[+-]?%d+$")
            or first:match("^[+-]?%d+%.0+$")
            or first:match("^%%[%w_]+$")
            or first:match("^%[%%[%w_]+%]$")
          ) then
            rows[#rows + 1] = r
            goto continue
          end
        end
      end
      rows[#rows + 1] = r
      saw_non_title = true
    end
    ::continue::
  end
  return rows
end

local function current_data_row_index(data_rows, row)
  for i, r in ipairs(data_rows) do
    if r == row then
      return i
    end
  end
  return nil
end

local function param_names_for_row(entry, row_index)
  if not entry or not entry.signature_rows or #entry.signature_rows == 0 then
    return nil
  end
  return entry.signature_rows[row_index] or entry.signature_rows[#entry.signature_rows]
end

local function first_data_row_is_nonnumeric(data_rows, lines)
  local first_row = data_rows and data_rows[1]
  if not first_row then return false end
  local values = split_csv_outside_quotes(lines[first_row] or "")
  local first = trim(values[1] or "")
  if first == "" or first:match('^".*"$') then return false end
  return not (
    first:match("^[+-]?%d+$")
    or first:match("^[+-]?%d+%.0+$")
    or first:match("^%%[%w_]+$")
    or first:match("^%[%%[%w_]+%]$")
  )
end

-- Generic: for keywords whose schema row 1 is a single optional ID (coid/bcid),
-- detect whether that row was omitted (first data row starts with non-numeric content).
local function schema_row_for_context(keyword, entry, data_rows, lines, row_index)
  if not first_data_row_is_nonnumeric(data_rows, lines) then
    return row_index
  end
  local sig = entry and entry.signature_rows
  if sig and sig[1] and #sig[1] == 1 and #sig >= 2 then
    local first_param = sig[1][1] or ""
    local is_id_like = first_param:match("^%d+$") or first_param:match("^[%a_]*[iI][dD]$")
    if is_id_like then
      return row_index + 1
    end
  end
  return row_index
end

local function field_index_from_col(line, col1)
  local in_quotes = false
  local idx = 1
  local seg_start = 1
  local i = 1
  while i <= #line do
    local ch = line:sub(i, i)
    if ch == '"' then
      in_quotes = not in_quotes
    elseif ch == "," and not in_quotes then
      if col1 >= seg_start and col1 <= i then
        return idx
      end
      idx = idx + 1
      seg_start = i + 1
    end
    i = i + 1
  end
  if col1 >= seg_start and col1 <= (#line + 1) then
    return idx
  end
  return nil
end

local function split_fields_with_spans(line)
  local out = {}
  local in_quotes = false
  local start_pos = 1
  local i = 1

  local function emit(end_pos)
    local seg = line:sub(start_pos, end_pos)
    local left = 1
    local right = #seg
    while left <= right and seg:sub(left, left):match("%s") do
      left = left + 1
    end
    while right >= left and seg:sub(right, right):match("%s") do
      right = right - 1
    end
    if left <= right then
      local text = seg:sub(left, right)
      local abs_start = start_pos + left - 1
      local abs_end = start_pos + right - 1
      out[#out + 1] = {
        text = text,
        start_col1 = abs_start,
        end_col1 = abs_end,
      }
    else
      out[#out + 1] = {
        text = "",
        start_col1 = start_pos,
        end_col1 = start_pos,
      }
    end
  end

  while i <= #line do
    local ch = line:sub(i, i)
    if ch == '"' then
      in_quotes = not in_quotes
    elseif ch == "," and not in_quotes then
      emit(i - 1)
      start_pos = i + 1
    end
    i = i + 1
  end
  emit(#line)

  return out
end

local function find_case_insensitive(haystack, needle)
  local h = (haystack or ""):lower()
  local n = (needle or ""):lower()
  if n == "" then
    return nil
  end
  return h:find(n, 1, true)
end

local function match_param_from_cword(entry)
  if not entry or not entry.params then
    return nil
  end
  local word = vim.fn.expand("<cword>") or ""
  local target = normalize_name(word)
  if target == "" then
    return nil
  end
  for _, p in ipairs(entry.params) do
    if normalize_name(p) == target then
      return p
    end
  end
  return nil
end

local function detect_context(buf, win)
  local lines, keyword_rows = ensure_parse_cache(buf)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col0 = cursor[1], cursor[2]
  local block = find_keyword_block(lines, keyword_rows, row)
  if not block then
    return nil, nil, nil
  end
  local entry = store.get_keyword(block.keyword)
  if not entry then
    return block.keyword, nil, nil
  end

  local current_line = lines[row] or ""
  if is_optional_title_line(current_line) then
    return block.keyword, "__OPTIONAL_TITLE__", { row_idx = nil, field_idx = nil, is_title = true }
  end

  local data_rows = collect_data_rows(lines, block)
  local row_idx = current_data_row_index(data_rows, row)
  if row_idx then
    local schema_row_idx = schema_row_for_context(block.keyword, entry, data_rows, lines, row_idx)
    local row_params = param_names_for_row(entry, schema_row_idx)
    if row_params then
      local line = lines[row] or ""
      local field_idx = field_index_from_col(line, col0 + 1)
      if field_idx and row_params[field_idx] then
        return block.keyword, row_params[field_idx], { row_idx = schema_row_idx, field_idx = field_idx, is_title = false }
      end
    end
  end

  local from_word = match_param_from_cword(entry)
  if from_word then
    return block.keyword, from_word, { row_idx = nil, field_idx = nil, is_title = false }
  end
  return block.keyword, nil, { row_idx = nil, field_idx = nil, is_title = false }
end

local function ensure_pane(source_buf, source_win)
  if state.suspend and not state.pane then
    -- Recover from stale suspend state after complex window close sequences.
    state.suspend = false
  end
  if state.suspend then
    return nil
  end
  if vim.v.exiting ~= vim.NIL and tonumber(vim.v.exiting) and tonumber(vim.v.exiting) ~= 0 then
    return nil
  end
  local pane = state.pane
  if pane
    and pane.buf
    and vim.api.nvim_buf_is_valid(pane.buf)
    and pane.win
    and vim.api.nvim_win_is_valid(pane.win)
  then
    return pane
  end

  local recovered = recover_existing_pane()
  if recovered then
    return recovered
  end

  local prev_win = vim.api.nvim_get_current_win()
  if source_win and vim.api.nvim_win_is_valid(source_win) then
    vim.api.nvim_set_current_win(source_win)
  end

  local ok_split = pcall(vim.cmd, "botright vsplit")
  if not ok_split then
    return nil
  end
  local help_win = vim.api.nvim_get_current_win()
  local help_buf = vim.api.nvim_create_buf(false, true)

  -- Register pane early to prevent recursive split creation while options trigger autocommands.
  state.pane = {
    win = help_win,
    buf = help_buf,
    source_buf = nil,
    source_win = nil,
    main_win = nil,
    keyword = nil,
    param = nil,
  }

  vim.b[help_buf].impetus_help_buffer = 1
  vim.b[help_buf].impetus_help_source = source_buf
  vim.w[help_win].impetus_help_window = 1

  vim.api.nvim_win_set_buf(help_win, help_buf)
  vim.api.nvim_win_set_width(help_win, config.get().side_help_width or 68)
  vim.bo[help_buf].buftype = "nofile"
  vim.bo[help_buf].bufhidden = "wipe"
  vim.bo[help_buf].swapfile = false
  vim.bo[help_buf].modifiable = false
  vim.bo[help_buf].filetype = "impetus"
  vim.bo[help_buf].syntax = "impetus"
  vim.wo[help_win].number = false
  vim.wo[help_win].relativenumber = false
  vim.wo[help_win].cursorline = false
  vim.wo[help_win].signcolumn = "no"
  vim.wo[help_win].wrap = false
  ensure_help_syntax(help_buf)

  if vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  end

  return state.pane
end

local function set_help_lines(help_buf, lines)
  vim.bo[help_buf].modifiable = true
  vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, lines)
  vim.bo[help_buf].modifiable = false
  ensure_help_syntax(help_buf)
end

local function apply_static_highlights(help_buf)
  vim.api.nvim_buf_clear_namespace(help_buf, state.ns_static, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
  for i, line in ipairs(lines) do
    local lnum = i - 1
    if line:match("^%s*%d*%.?%s*%*[%w_%-]+") then
      vim.api.nvim_buf_add_highlight(help_buf, state.ns_static, "impetusKeyword", lnum, 0, -1)
    end
    if line == '"Optional title"' then
      vim.api.nvim_buf_add_highlight(help_buf, state.ns_static, "impetusString", lnum, 0, -1)
    end
    if line:match("^%-+$") then
      vim.api.nvim_buf_add_highlight(help_buf, state.ns_static, "impetusDivider", lnum, 0, -1)
    end
    if line:match("^%s*Variable") then
      vim.api.nvim_buf_add_highlight(help_buf, state.ns_static, "impetusHeader", lnum, 0, -1)
    end
    if line:lower():match("%f[%a]options:%f[%A]") then
      local s, e = line:lower():find("options:")
      if s and e then
        vim.api.nvim_buf_add_highlight(help_buf, state.ns_static, "impetusOptions", lnum, s - 1, e)
      end
    end
    if line:lower():match("%f[%a]default:%f[%A]") then
      local s, e = line:lower():find("default:")
      if s and e then
        vim.api.nvim_buf_add_highlight(help_buf, state.ns_static, "impetusDefault", lnum, s - 1, e)
      end
    end
  end

  local in_example = false
  for i, line in ipairs(lines) do
    local normalized = trim(strip_number_prefix(line or "")):lower()
    local lnum = i - 1
    if normalized:match("^[#$]?%s*example%s*$") then
      in_example = true
      vim.api.nvim_buf_add_highlight(help_buf, state.ns_static, "impetusExample", lnum, 0, -1)
    elseif in_example then
      vim.api.nvim_buf_add_highlight(help_buf, state.ns_static, "impetusExample", lnum, 0, -1)
      if normalized:match("^[#$]?%s*end%s*$") then
        in_example = false
      end
    end
  end
end

local function collect_signature_rows_from_help(lines)
  local sep = nil
  for i, line in ipairs(lines) do
    local normalized = trim(strip_number_prefix(line or ""))
    if normalized:match("^%-+$") then
      sep = i
      break
    end
  end
  local upper = (sep and (sep - 1)) or #lines
  local rows = {}
  for i = 2, upper do
    local line = lines[i] or ""
    if not is_separator_or_meta(line) then
      rows[#rows + 1] = { idx = i, text = line }
    end
  end
  return rows
end

local function highlight_precise_signature_slot(help_buf, lines, ctx)
  if not ctx or not ctx.row_idx or not ctx.field_idx then
    return false
  end
  local rows = collect_signature_rows_from_help(lines)
  local r = rows[ctx.row_idx]
  if not r then
    return false
  end
  local lnum = r.idx - 1
  local line = r.text
  if line:find(",", 1, true) then
    local fields = split_fields_with_spans(line)
    local f = fields[ctx.field_idx]
    if not f then
      return false
    end
    vim.api.nvim_buf_add_highlight(help_buf, state.ns_active, "impetusHelpActiveParam", lnum, f.start_col1 - 1, f.end_col1)
    return true
  end
  local first = line:find("%S") or 1
  local last = #line
  while last >= first and line:sub(last, last):match("%s") do
    last = last - 1
  end
  if last < first then
    return false
  end
  vim.api.nvim_buf_add_highlight(help_buf, state.ns_active, "impetusHelpActiveParam", lnum, first - 1, last)
  return true
end

local function apply_active_param_highlight(help_buf, keyword, param_name, ctx)
  vim.api.nvim_buf_clear_namespace(help_buf, state.ns_active, 0, -1)
  if not param_name or param_name == "" then
    return
  end

  if param_name == "__OPTIONAL_TITLE__" then
    local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
    for i, line in ipairs(lines) do
      if is_optional_title_line(line) then
        vim.api.nvim_buf_add_highlight(help_buf, state.ns_active, "impetusHelpActiveLine", i - 1, 0, -1)
      end
    end
    return
  end

  local target_raw = trim(param_name)
  local target = normalize_name(target_raw)
  local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
  highlight_precise_signature_slot(help_buf, lines, ctx)

  for i, line in ipairs(lines) do
    local lnum = i - 1
    local before_colon = line:match("^%s*(.-)%s*:")
    if before_colon and normalize_name(before_colon) == target then
      vim.api.nvim_buf_add_highlight(help_buf, state.ns_active, "impetusHelpActiveLine", lnum, 0, -1)
      local bs = line:find(before_colon, 1, true)
      if bs then
        local be = bs + #before_colon - 1
        vim.api.nvim_buf_add_highlight(help_buf, state.ns_active, "impetusHelpActiveParam", lnum, bs - 1, be)
      end
    end
    if before_colon and before_colon:find(",", 1, true) then
      local fields = split_fields_with_spans(before_colon)
      for _, f in ipairs(fields) do
        if normalize_name(f.text) == target then
          local raw_pos = find_case_insensitive(f.text, target_raw)
          if raw_pos then
            local hs = (f.start_col1 - 1) + raw_pos - 1
            local he = hs + #target_raw
            vim.api.nvim_buf_add_highlight(help_buf, state.ns_active, "impetusHelpActiveParam", lnum, hs, he)
          else
            vim.api.nvim_buf_add_highlight(help_buf, state.ns_active, "impetusHelpActiveParam", lnum, f.start_col1 - 1, f.end_col1)
          end
        end
      end
    end

    if line:find(",", 1, true) then
      local fields = split_fields_with_spans(line)
      for _, f in ipairs(fields) do
        if normalize_name(f.text) == target and f.end_col1 >= f.start_col1 then
          local raw_pos = find_case_insensitive(f.text, target_raw)
          if raw_pos then
            local hs = (f.start_col1 - 1) + raw_pos - 1
            local he = hs + #target_raw
            vim.api.nvim_buf_add_highlight(help_buf, state.ns_active, "impetusHelpActiveParam", lnum, hs, he)
          else
          vim.api.nvim_buf_add_highlight(
            help_buf,
            state.ns_active,
            "impetusHelpActiveParam",
            lnum,
            f.start_col1 - 1,
            f.end_col1
          )
          end
        end
      end
    else
      local normalized_line = normalize_name(line)
      if normalized_line == target then
        local raw_pos = find_case_insensitive(line, target_raw)
        if raw_pos then
          local hs = raw_pos - 1
          local he = hs + #target_raw
          vim.api.nvim_buf_add_highlight(help_buf, state.ns_active, "impetusHelpActiveParam", lnum, hs, he)
        else
          vim.api.nvim_buf_add_highlight(help_buf, state.ns_active, "impetusHelpActiveParam", lnum, 0, -1)
        end
      end
    end
  end
end

function M.render(source_buf, source_win)
  if vim.g.impetus_opening_child == 1 then
    return
  end
  source_buf, source_win = resolve_primary_source(source_buf, source_win)
  if not vim.api.nvim_buf_is_valid(source_buf) then
    return
  end
  if vim.b[source_buf].impetus_info_buffer == 1 then
    return
  end
  if vim.b[source_buf].impetus_help_buffer == 1 then
    return
  end

  local keyword, param, ctx = detect_context(source_buf, source_win)
  local pane = ensure_pane(source_buf, source_win)
  if not pane then
    return
  end
  if not (pane.buf and vim.api.nvim_buf_is_valid(pane.buf)) then
    return
  end

  if not keyword then
    set_help_lines(pane.buf, { "No Impetus keyword under cursor." })
    pane.keyword = nil
    pane.param = nil
    return
  end

  local entry = store.get_keyword(keyword)
  local lines = nil
  if entry and entry.help_lines and #entry.help_lines > 0 then
    lines = entry.help_lines
  else
    lines = { keyword, "(No help block found in commands.help)" }
  end

  if pane.keyword ~= keyword then
    set_help_lines(pane.buf, lines)
    apply_static_highlights(pane.buf)
    pane.source_buf = source_buf
    pane.keyword = keyword
    pane.param = nil
  end
  local is_nav = source_win and vim.api.nvim_win_is_valid(source_win) and vim.w[source_win].impetus_nav_window == 1
  if source_win and vim.api.nvim_win_is_valid(source_win) then
    pane.source_win = source_win
    pane.source_buf = source_buf
    if not is_nav and vim.w[source_win].impetus_child_window ~= 1 then
      if not pane.main_win or not vim.api.nvim_win_is_valid(pane.main_win) then
        pane.main_win = source_win
      end
    end
  end

  -- Re-apply every time for deterministic behavior after cursor moves/colorscheme updates.
  apply_active_param_highlight(pane.buf, keyword, param, ctx)
  pane.param = param
end

function M.close_for_buffer(source_buf)
  local pane = state.pane or recover_existing_pane()
  if not pane then
    return
  end
  if source_buf and pane.source_buf and source_buf ~= pane.source_buf then
    return
  end
  if pane.win and vim.api.nvim_win_is_valid(pane.win) then
    pcall(vim.api.nvim_win_close, pane.win, true)
  end
  state.pane = nil
end

function M.close_for_current(manual)
  if manual ~= false then
    state.user_closed = true
  end
  state.suspend = true
  -- Force-close all help panes found in current tabpage/session.
  local hs = list_help_windows()
  for _, it in ipairs(hs) do
    if it.win and vim.api.nvim_win_is_valid(it.win) then
      pcall(vim.api.nvim_win_close, it.win, true)
    end
  end
  -- Also clear tracked pane state in case windows were already invalid.
  M.close_for_buffer(nil)
  vim.schedule(function()
    state.suspend = false
  end)
end

function M.is_open()
  if #list_help_windows() > 0 then
    return true
  end
  local pane = state.pane or recover_existing_pane()
  return pane ~= nil and pane.win and vim.api.nvim_win_is_valid(pane.win)
end

function M.get_debug_state()
  local pane = state.pane or recover_existing_pane()
  local out = {
    user_closed = state.user_closed,
    suspend = state.suspend,
    opening_child = (vim.g.impetus_opening_child == 1),
    has_pane = pane ~= nil,
  }
  if pane then
    out.win = pane.win
    out.buf = pane.buf
    out.source_win = pane.source_win
    out.source_buf = pane.source_buf
    out.main_win = pane.main_win
  end
  return out
end

function M.open_for_current()
  if state.suspend and not state.pane then
    state.suspend = false
  end
  state.user_closed = false
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  buf, win = resolve_primary_source(buf, win)
  M.render(buf, win)
end

function M.attach_buffer(buf)
  if vim.b[buf].impetus_help_attached == 1 then
    return
  end
  vim.b[buf].impetus_help_attached = 1
  if state.user_closed then
    return
  end
  M.render(buf, vim.api.nvim_get_current_win())
end

function M.setup()
  local group = vim.api.nvim_create_augroup("ImpetusSideHelp", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
    group = group,
    callback = function(ev)
      local buf = ev.buf
      local cur_win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_is_valid(cur_win) and vim.w[cur_win].impetus_nav_window == 1 then
        return
      end
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.b[buf].impetus_info_buffer == 1 then
        return
      end
      if vim.b[buf].impetus_help_buffer == 1 then
        return
      end
      if state.suspend then
        return
      end
      if vim.g.impetus_fast_nav == 1 then
        return
      end
      if vim.v.exiting ~= vim.NIL and tonumber(vim.v.exiting) and tonumber(vim.v.exiting) ~= 0 then
        return
      end
      if state.user_closed then
        return
      end
      if vim.g.impetus_opening_child == 1 then
        return
      end
      local ft = vim.bo[buf].filetype
      if not vim.tbl_contains(config.get().filetypes or {}, ft) then
        return
      end
      M.render(buf, cur_win)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      state.parse_cache[ev.buf] = nil
      -- Do not close help pane on BufWipeout.
      -- Child buffers can be wiped while main window is still active.
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      state.suspend = true
      local pane = state.pane
      if not pane then
        vim.schedule(function()
          state.suspend = false
        end)
        return
      end
      local closed_win = tonumber(ev.match)
      if not closed_win then
        vim.schedule(function()
          state.suspend = false
        end)
        return
      end
      if pane.win and closed_win == pane.win then
        local main_win = pane.main_win
        local main_buf = pane.source_buf
        state.pane = nil
        vim.schedule(function()
          state.suspend = false
          if state.user_closed then
            return
          end
          if not (main_win and vim.api.nvim_win_is_valid(main_win)) then
            return
          end
          if not (main_buf and vim.api.nvim_buf_is_valid(main_buf)) then
            main_buf = vim.api.nvim_win_get_buf(main_win)
          end
          if not (main_buf and vim.api.nvim_buf_is_valid(main_buf)) then
            return
          end
          local ft = vim.bo[main_buf].filetype
          if not vim.tbl_contains(config.get().filetypes or {}, ft) then
            return
          end
          M.render(main_buf, main_win)
        end)
        return
      end
      if pane.main_win and closed_win == pane.main_win then
        vim.schedule(function()
          if state.pane and state.pane.win and vim.api.nvim_win_is_valid(state.pane.win) then
            pcall(vim.api.nvim_win_close, state.pane.win, true)
          end
          state.pane = nil
          state.suspend = false
        end)
      else
        vim.schedule(function()
          state.suspend = false
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      state.suspend = true
      local pane = state.pane
      if not pane then
        return
      end
      if pane.win and vim.api.nvim_win_is_valid(pane.win) then
        pcall(vim.api.nvim_win_close, pane.win, true)
      end
      state.pane = nil
    end,
  })
end

return M
