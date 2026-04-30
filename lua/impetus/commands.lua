local store = require("impetus.store")
local snippets = require("impetus.snippets")
local lint = require("impetus.lint")
local side_help = require("impetus.side_help")
local config = require("impetus.config")
local analysis = require("impetus.analysis")
local actions = require("impetus.actions")
local info = require("impetus.info")
local intrinsic = require("impetus.intrinsic")
local log = require("impetus.log")

local M = {}

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_param_name(s)
  return ((s or ""):gsub("^%%", ""):gsub("^%[", ""):gsub("%]$", ""))
end

local function param_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.fn.col(".") -- 1-based

  -- Bracket form support: [%name], works when cursor is on [, %, name, or ].
  local bsearch = 1
  while bsearch <= #line do
    local s, e, inner = line:find("%[([^%[%]]-)%]", bsearch)
    if not s then
      break
    end
    if col >= s and col <= e then
      local pname = (inner or ""):match("%%([%a_][%w_]*)")
      if pname then
        return pname
      end
    end
    bsearch = e + 1
  end

  -- Robust token detection: works when cursor is on '%' or any character in name.
  local search = 1
  while search <= #line do
    local s, e, name = line:find("%%([%a_][%w_]*)", search)
    if not s then
      break
    end
    if col >= s and col <= e then
      return name
    end
    search = e + 1
  end

  local left = line:sub(1, col)
  local p = left:match("%%([%a_][%w_]*)$")
  if p then
    return p
  end

  local cword = vim.fn.expand("<cword>") or ""
  cword = cword:gsub("^%%", "")
  if cword:match("^[%a_][%w_]*$") then
    return cword
  end
  return nil
end

-- Split a CSV line into fields, preserving each field's start/end column positions.
local function split_csv_with_positions(line)
  local values = {}
  local in_quotes = false
  local start_pos = 1
  local i = 1
  while i <= #line do
    local ch = line:sub(i, i)
    if ch == '"' then
      in_quotes = not in_quotes
    elseif ch == "," and not in_quotes then
      values[#values + 1] = { text = trim(line:sub(start_pos, i - 1)), start = start_pos, finish = i - 1 }
      start_pos = i + 1
    end
    i = i + 1
  end
  values[#values + 1] = { text = trim(line:sub(start_pos)), start = start_pos, finish = #line }
  return values
end

-- If the cursor is on a value like fcn(1000) or crv(1000), and the parameter
-- description in commands.help mentions function/curve, treat it as an object ID.
local function cursor_fcn_crv_id()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col0 = cursor[1], cursor[2]
  local line = lines[row] or ""

  -- 1. Find current keyword
  local keyword = nil
  for r = row, 1, -1 do
    local kw = trim(lines[r] or ""):match("^%*[%u%d_%-]+")
    if kw then
      keyword = kw
      break
    end
  end
  if not keyword then
    return nil
  end

  -- 2. Split current line into CSV fields
  local values = split_csv_with_positions(line)
  if #values == 0 then
    return nil
  end

  -- 3. Locate the field under cursor
  local col1 = col0 + 1
  local field_idx = nil
  local field_value = nil
  for fi, v in ipairs(values) do
    if col1 >= v.start and col1 <= v.finish then
      field_idx = fi
      field_value = v.text
      break
    end
  end
  if not field_idx then
    -- Cursor may be in trailing whitespace; use last non-empty field
    for fi = #values, 1, -1 do
      if values[fi].text ~= "" then
        field_idx = fi
        field_value = values[fi].text
        break
      end
    end
  end
  if not field_value or field_value == "" then
    return nil
  end

  -- 4. Check for fcn(id) / crv(id) / dfcn(id) pattern
  local id, prefix = nil, nil
  local is_embedded = false

  -- 4a. Full-field match (legacy)
  id = field_value:match("^fcn%s*%(%s*(%d+)%s*%)")
  if id then
    prefix = "fcn"
  end
  if not id then
    id = field_value:match("^crv%s*%(%s*(%d+)%s*%)")
    if id then
      prefix = "crv"
    end
  end

  -- 4b. Embedded match: fcn(id) / crv(id) / dfcn(id) anywhere in expression
  if not id then
    local field_start = values[field_idx] and values[field_idx].start or 1
    local pos = 1
    while pos <= #field_value do
      local s, e, p, num = field_value:find("(%a+)%s*%(%s*(%d+)%s*%)", pos)
      if not s then break end
      local pl = p:lower()
      if pl == "fcn" or pl == "crv" or pl == "dfcn" then
        local abs_s = field_start + s - 1
        local abs_e = field_start + e - 1
        if col1 >= abs_s and col1 <= abs_e then
          id = num
          prefix = pl
          is_embedded = true
          break
        end
      end
      pos = e + 1
    end
  end

  if not id then
    return nil
  end

  -- 5. For full-field match, verify description supports function/curve reference
  if not is_embedded then
    local entry = store.get_keyword(keyword)
    if not entry or not entry.signature_rows then
      return nil
    end
    for _, schema in ipairs(entry.signature_rows) do
      local param_name = schema[field_idx]
      if param_name then
        local desc = (entry.descriptions and entry.descriptions[param_name]) or ""
        local desc_lower = desc:lower()
        if prefix == "fcn" then
          if desc_lower:find("fcn", 1, true) or desc_lower:find("function", 1, true) then
            return "curve", id, prefix
          end
        elseif prefix == "crv" then
          if desc_lower:find("crv", 1, true) or desc_lower:find("curve", 1, true) then
            return "curve", id, prefix
          end
        end
      end
    end
    return nil
  end

  return "curve", id, prefix
end

local function to_qf_items(bufnr, items, kind)
  local out = {}
  for _, it in ipairs(items or {}) do
    out[#out + 1] = {
      bufnr = bufnr,
      lnum = it.row or 1,
      col = (it.col or 0) + 1,
      text = string.format("[%s] %s", kind, it.line or ""),
    }
  end
  return out
end

local function dedupe_param_refs(refs)
  refs = refs or { defs = {}, refs = {} }
  local out_defs, out_refs = {}, {}
  local seen_defs = {}
  for _, d in ipairs(refs.defs or {}) do
    local key = string.format("%s:%d:%d", d.file or "", d.row or 0, d.col or 0)
    if not seen_defs[key] then
      seen_defs[key] = true
      out_defs[#out_defs + 1] = d
    end
  end
  local seen_refs = {}
  for _, r in ipairs(refs.refs or {}) do
    local key = string.format("%s:%d:%d", r.file or "", r.row or 0, r.col or 0)
    if not seen_defs[key] and not seen_refs[key] then
      seen_refs[key] = true
      out_refs[#out_refs + 1] = r
    end
  end
  return { defs = out_defs, refs = out_refs }
end

local function jump_to_item(it)
  if not it then
    return
  end
  local row = it.row or 1
  local col = it.col or 0
  if it.file and it.file ~= "" then
    local cur_file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
    if it.file ~= cur_file then
      -- Open in nav_win (left split), keep main window untouched
      info.open_in_nav_win(it.file, row, col)
      return
    end
  end
  vim.api.nvim_win_set_cursor(0, { row, col })
  vim.cmd("normal! zz")
end

local function show_param_refs_popup(items, param_name)
  local this_file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local has_cross_file = false
  for _, it in ipairs(items or {}) do
    if it.file and it.file ~= "" and it.file ~= this_file then
      has_cross_file = true
      break
    end
  end
  local title = "Refs for %" .. normalize_param_name(param_name or "")
  local lines = {}
  local line_kw_tags = {}   -- [i] = { col_start=<0-based>, kw=<string> } or nil
  for i, it in ipairs(items or {}) do
    local file_tag = ""
    if has_cross_file then
      local fname = (it.file and it.file ~= "") and vim.fn.fnamemodify(it.file, ":t") or "?"
      file_tag = "[" .. fname .. "] "
    end
    local base = string.format("%2d [%s] %sL%-5d %s", i, it.kind or "ref", file_tag, it.row or 1, trim(it.line or ""))
    if it.keyword and it.keyword ~= "" then
      -- Append "  *KEYWORD" and record its start column for highlighting
      line_kw_tags[i] = { col_start = #base + 2, kw = it.keyword }
      lines[#lines + 1] = base .. "  " .. it.keyword
    else
      lines[#lines + 1] = base
    end
  end
  if #lines == 0 then
    vim.notify("No refs for %" .. normalize_param_name(param_name), vim.log.levels.INFO)
    return
  end

  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
  end
  width = math.min(width, math.max(40, math.floor(vim.o.columns * 0.85)))
  local height = math.min(#lines, math.max(6, math.floor(vim.o.lines * 0.5)))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = "impetus"
  vim.b[buf].impetus_popup_buffer = 1

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  local idx_groups = { "impetusNumber", "impetusKeyword", "impetusParam", "impetusOptions", "impetusDefault" }
  local needle = normalize_param_name(param_name or "")
  for i, l in ipairs(lines) do
    local lnum = i - 1
    local idx_txt = tostring(i)
    local start_idx = l:find(idx_txt, 1, true) or 1
    local g = idx_groups[((i - 1) % #idx_groups) + 1]
    vim.api.nvim_buf_add_highlight(buf, -1, g, lnum, start_idx - 1, start_idx - 1 + #idx_txt)

    local lb = l:find("%[", 1, true)
    local rb = l:find("%]", 1, true)
    if lb and rb and rb > lb then
      vim.api.nvim_buf_add_highlight(buf, -1, "impetusHeader", lnum, lb - 1, rb)
    end

    if needle ~= "" then
      local p1 = l:find("%%" .. needle, 1, true)
      if p1 then
        vim.api.nvim_buf_add_highlight(buf, -1, "impetusParam", lnum, p1 - 1, p1 - 1 + #needle + 1)
      else
        local p2 = l:find(needle, 1, true)
        if p2 then
          vim.api.nvim_buf_add_highlight(buf, -1, "impetusParam", lnum, p2 - 1, p2 - 1 + #needle)
        end
      end
    end
    -- Highlight the keyword tag appended at the end of the line (e.g. "  *PART")
    local kw_info = line_kw_tags[i]
    if kw_info then
      vim.api.nvim_buf_add_highlight(buf, -1, "impetusKeyword", lnum, kw_info.col_start, kw_info.col_start + #kw_info.kw)
    end
  end

  local function close_popup()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  local function accept_current()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local it = items[row]
    close_popup()
    if it then
      vim.schedule(function()
        jump_to_item(it)
      end)
    end
  end

  vim.keymap.set("n", "j", "gj", { buffer = buf, silent = true })
  vim.keymap.set("n", "k", "gk", { buffer = buf, silent = true })
  vim.keymap.set("n", "<Down>", "gj", { buffer = buf, silent = true })
  vim.keymap.set("n", "<Up>", "gk", { buffer = buf, silent = true })
  vim.keymap.set("n", "<CR>", accept_current, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Space>", accept_current, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", close_popup, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close_popup, { buffer = buf, silent = true })
end

local function capture_cursor_highlight_probe()
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local col1 = math.max(col0 + 1, 1)
  local syn_id = vim.fn.synID(row, col1, 1)
  local trans_id = vim.fn.synIDtrans(syn_id)
  local syn_name = vim.fn.synIDattr(syn_id, "name")
  local trans_name = vim.fn.synIDattr(trans_id, "name")
  local line = vim.api.nvim_get_current_line()
  vim.g.impetus_last_hl_probe = {
    file = vim.api.nvim_buf_get_name(0),
    row = row,
    col = col0,
    filetype = vim.bo.filetype,
    syn_id = syn_id,
    syn_name = syn_name,
    trans_id = trans_id,
    trans_name = trans_name,
    pumvisible = vim.fn.pumvisible(),
    line = line,
  }
  local msg = string.format(
    "[impetus hl probe] ft=%s row=%d col=%d syn=%s trans=%s pum=%d",
    tostring(vim.bo.filetype),
    row,
    col0,
    tostring(syn_name),
    tostring(trans_name),
    tonumber(vim.fn.pumvisible()) or 0
  )
  vim.api.nvim_echo({ { msg, "WarningMsg" } }, false, {})
end

local function arm_highlight_probe()
  local group = vim.api.nvim_create_augroup("ImpetusHighlightProbeOnce", { clear = true })
  local fired = false
  vim.g.impetus_last_hl_probe = {
    status = "armed",
    file = vim.api.nvim_buf_get_name(0),
    filetype = vim.bo.filetype,
  }
  vim.api.nvim_create_autocmd({ "TextChangedI", "CompleteChanged", "CompleteDone", "CompleteDonePre", "CursorMovedI" }, {
    group = group,
    pattern = "*",
    callback = function(ev)
      if fired then
        return
      end
      fired = true
      vim.schedule(function()
        vim.g.impetus_last_hl_probe_event = ev.event
        pcall(capture_cursor_highlight_probe)
        pcall(vim.api.nvim_del_augroup_by_id, group)
      end)
    end,
    desc = "Capture cursor highlight during next completion state change",
  })
  vim.api.nvim_echo({
    { "[impetus hl probe] armed, trigger completion once", "WarningMsg" },
  }, false, {})
end

local function add_alias(name, target_cmd)
  vim.api.nvim_create_user_command(name, function(opts)
    local args = opts.args or ""
    if args ~= "" then
      vim.cmd(target_cmd .. " " .. args)
    else
      vim.cmd(target_cmd)
    end
  end, { nargs = "*" })
end

local function best_help_path()
  return store.get_path() or config.get().help_file
end

local function render_debug_lines()
  local function push_multiline(lines, text)
    for _, s in ipairs(vim.split(text or "", "\n", { plain = true, trimempty = false })) do
      lines[#lines + 1] = s
    end
  end

  local lines = {}
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_get_current_buf()
  lines[#lines + 1] = "Impetus Window Debug"
  lines[#lines + 1] = string.rep("-", 60)
  lines[#lines + 1] = string.format("current_win=%d current_buf=%d", cur_win, cur_buf)

  local info_state = info.get_debug_state and info.get_debug_state() or nil
  local help_state = side_help.get_debug_state and side_help.get_debug_state() or nil

  lines[#lines + 1] = ""
  lines[#lines + 1] = "[info]"
  if info_state then
    push_multiline(lines, vim.inspect(info_state))
  else
    lines[#lines + 1] = "nil"
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "[help]"
  if help_state then
    push_multiline(lines, vim.inspect(help_state))
  else
    lines[#lines + 1] = "nil"
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "[windows]"
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local ok_buf, b = pcall(vim.api.nvim_win_get_buf, w)
    if ok_buf then
      local path = vim.api.nvim_buf_get_name(b)
      if path == "" then
        path = "[No Name]"
      end
      lines[#lines + 1] = string.format(
        "win=%d buf=%d child_win=%s nav_win=%s child_buf=%s help_buf=%s info_buf=%s path=%s",
        w,
        b,
        tostring(vim.w[w].impetus_child_window == 1),
        tostring(vim.w[w].impetus_nav_window == 1),
        tostring(vim.b[b].impetus_child_buffer == 1),
        tostring(vim.b[b].impetus_help_buffer == 1),
        tostring(vim.b[b].impetus_info_buffer == 1),
        path
      )
    end
  end
  return lines
end

local function render_doctor_lines()
  local function push_multiline(lines, text)
    for _, s in ipairs(vim.split(text or "", "\n", { plain = true, trimempty = false })) do
      lines[#lines + 1] = s
    end
  end

  local lines = {}
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_get_current_buf()
  lines[#lines + 1] = "Impetus Doctor"
  lines[#lines + 1] = string.rep("-", 60)
  lines[#lines + 1] = string.format("current_win=%d current_buf=%d ft=%s", cur_win, cur_buf, vim.bo[cur_buf].filetype or "")
  lines[#lines + 1] = string.format("g:mapleader=%s g:maplocalleader=%s", tostring(vim.g.mapleader), tostring(vim.g.maplocalleader))
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[maparg]"
  push_multiline(lines, ",h => " .. vim.inspect(vim.fn.maparg(",h", "n", false, true)))
  push_multiline(lines, "<leader>h => " .. vim.inspect(vim.fn.maparg("<leader>h", "n", false, true)))
  push_multiline(lines, "<localleader>h => " .. vim.inspect(vim.fn.maparg("<localleader>h", "n", false, true)))
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[window flags]"
  lines[#lines + 1] = string.format(
    "cur: child_win=%s nav_win=%s help_win=%s child_buf=%s help_buf=%s info_buf=%s",
    tostring(vim.w[cur_win].impetus_child_window == 1),
    tostring(vim.w[cur_win].impetus_nav_window == 1),
    tostring(vim.w[cur_win].impetus_help_window == 1),
    tostring(vim.b[cur_buf].impetus_child_buffer == 1),
    tostring(vim.b[cur_buf].impetus_help_buffer == 1),
    tostring(vim.b[cur_buf].impetus_info_buffer == 1)
  )
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[help state]"
  push_multiline(lines, vim.inspect(side_help.get_debug_state and side_help.get_debug_state() or nil))
  return lines
end

local function render_fold_doctor_lines()
  local function push_multiline(lines, text)
    for _, s in ipairs(vim.split(text or "", "\n", { plain = true, trimempty = false })) do
      lines[#lines + 1] = s
    end
  end

  local function directive_kind(line)
    local t = trim((line or ""):gsub("^%s*%d+%.%s*", ""))
    if t:match("^~if%f[%A]") then return "if_start" end
    if t:match("^~else_if%f[%A]") then return "if_mid" end
    if t:match("^~else%f[%A]") then return "if_mid" end
    if t:match("^~end_if%f[%A]") then return "if_end" end
    if t:match("^~repeat%f[%A]") then return "repeat_start" end
    if t:match("^~end_repeat%f[%A]") then return "repeat_end" end
    if t:match("^~convert_from_") then return "convert_start" end
    if t:match("^~end_convert%f[%A]") then return "convert_end" end
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

  local lines = {}
  local buf = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cur = all[row] or ""
  local kind = directive_kind(cur)
  local srow, erow = nil, nil
  if kind == "convert_start" then
    srow = row
    erow = matching_end_row_for_start(all, row, "convert_start", "convert_end")
  elseif kind == "convert_end" then
    srow = matching_start_row_for_end(all, row, "convert_end", "convert_start")
    erow = row
  elseif kind == "if_start" or kind == "if_mid" then
    srow = row
    erow = matching_end_row_for_start(all, row, "if_start", "if_end")
  elseif kind == "if_end" then
    srow = matching_start_row_for_end(all, row, "if_end", "if_start")
    erow = row
  elseif kind == "repeat_start" then
    srow = row
    erow = matching_end_row_for_start(all, row, "repeat_start", "repeat_end")
  elseif kind == "repeat_end" then
    srow = matching_start_row_for_end(all, row, "repeat_end", "repeat_start")
    erow = row
  end

  local foldlevel_cur = vim.fn.foldlevel(row)
  local foldexpr_opt = vim.wo.foldexpr
  local foldclosed_cur = vim.fn.foldclosed(row)
  local foldclosed_s = (srow and vim.fn.foldclosed(srow)) or -2

  lines[#lines + 1] = "Impetus Fold Doctor"
  lines[#lines + 1] = string.rep("-", 60)
  lines[#lines + 1] = string.format("buf=%d row=%d col=%d ft=%s", buf, row, col, vim.bo[buf].filetype or "")
  lines[#lines + 1] = string.format("foldmethod=%s foldenable=%s foldlevel=%s", vim.wo.foldmethod or "", tostring(vim.wo.foldenable), tostring(vim.wo.foldlevel))
  lines[#lines + 1] = string.format("foldexpr_opt=%s", tostring(foldexpr_opt))
  push_multiline(lines, "maparg(,t)=" .. vim.inspect(vim.fn.maparg(",t", "n", false, true)))
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("current_line=%s", cur)
  lines[#lines + 1] = string.format("directive_kind=%s", tostring(kind))
  lines[#lines + 1] = string.format("range_start=%s range_end=%s", tostring(srow), tostring(erow))
  lines[#lines + 1] = string.format("foldlevel(cur)=%s foldclosed(cur)=%s foldclosed(start)=%s", tostring(foldlevel_cur), tostring(foldclosed_cur), tostring(foldclosed_s))

  if srow and erow then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("start_line=%s", all[srow] or "")
    lines[#lines + 1] = string.format("end_line=%s", all[erow] or "")
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "[window flags]"
  lines[#lines + 1] = string.format(
    "child_win=%s nav_win=%s help_win=%s child_buf=%s help_buf=%s info_buf=%s",
    tostring(vim.w[vim.api.nvim_get_current_win()].impetus_child_window == 1),
    tostring(vim.w[vim.api.nvim_get_current_win()].impetus_nav_window == 1),
    tostring(vim.w[vim.api.nvim_get_current_win()].impetus_help_window == 1),
    tostring(vim.b[buf].impetus_child_buffer == 1),
    tostring(vim.b[buf].impetus_help_buffer == 1),
    tostring(vim.b[buf].impetus_info_buffer == 1)
  )

  if kind == nil then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Hint: cursor is not on a control directive line."
  end

  if type(actions.toggle_fold_here) ~= "function" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "ERROR: actions.toggle_fold_here missing"
  end

  push_multiline(lines, "")
  return lines
end

local function strip_number_prefix(line)
  return ((line or ""):gsub("^%s*%d+%.%s*", ""))
end

local function parse_keyword(line)
  local normalized = trim(strip_number_prefix(line))
  return normalized:match("^(%*[%w_%-]+)")
end

local function split_keyword_blocks(lines)
  local blocks = {}
  local start_row, kw = nil, nil
  for i, line in ipairs(lines or {}) do
    local k = parse_keyword(line)
    if k then
      if start_row then
        blocks[#blocks + 1] = { start_row = start_row, end_row = i - 1, keyword = kw }
      end
      start_row = i
      kw = k
    end
  end
  if start_row then
    blocks[#blocks + 1] = { start_row = start_row, end_row = #lines, keyword = kw }
  end
  return blocks
end

local function is_comment_line(line)
  local t = trim(strip_number_prefix(line))
  local c = t:sub(1, 1)
  return c == "#" or c == "$"
end

local function is_blank_line(line)
  return trim(line or "") == ""
end

local function is_comma_only_line(line)
  local t = trim(strip_number_prefix(line))
  if t == "" then
    return false
  end
  return t:match("^[,%s]+$") ~= nil
end

local function is_meta_row(line)
  local t = trim(strip_number_prefix(line))
  if t == "" then
    return true
  end
  if t:sub(1, 1) == "~" then
    return true
  end
  if t:match('^".*"$') then
    return true
  end
  if t:sub(1, 1) == "#" or t:sub(1, 1) == "$" then
    return true
  end
  return false
end

local function clean_current_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = split_keyword_blocks(lines)
  if #blocks == 0 then
    return 0, {}
  end

  local out = {}
  local removed = 0
  local entries = {}

  -- Preamble: blank/comment lines before the first keyword block
  for r = 1, blocks[1].start_row - 1 do
    local line = lines[r] or ""
    if is_comment_line(line) or is_blank_line(line) then
      removed = removed + 1
      entries[#entries + 1] = { row = r, line = line, reason = is_comment_line(line) and "comment" or "blank" }
    else
      out[#out + 1] = line
    end
  end

  for _, b in ipairs(blocks) do
    local keyword_upper = b.keyword:upper()
    local entry = store.get_keyword(keyword_upper)
    local sig_rows = entry and entry.signature_rows or nil
    local keyword_line = lines[b.start_row] or ""
    -- Normalize lowercase keyword to uppercase
    keyword_line = keyword_line:gsub(vim.pesc(b.keyword), keyword_upper)
    out[#out + 1] = keyword_line

    -- Gather non-comment lines inside the block
    local block_lines = {}
    local block_rows = {}
    for r = b.start_row + 1, b.end_row do
      local line = lines[r] or ""
      if is_comment_line(line) then
        removed = removed + 1
        entries[#entries + 1] = { row = r, line = line, reason = "comment" }
      else
        block_lines[#block_lines + 1] = line
        block_rows[#block_rows + 1] = r
      end
    end

    -- Remove leading blank lines (conservative: blank lines at the start of a block)
    while #block_lines > 0 and is_blank_line(block_lines[1]) do
      entries[#entries + 1] = { row = block_rows[1], line = block_lines[1], reason = "leading-blank" }
      table.remove(block_lines, 1)
      table.remove(block_rows, 1)
      removed = removed + 1
    end

    -- Remove trailing blank lines (conservative: blank lines at the end of a block)
    while #block_lines > 0 and is_blank_line(block_lines[#block_lines]) do
      entries[#entries + 1] = { row = block_rows[#block_rows], line = block_lines[#block_lines], reason = "trailing-blank" }
      table.remove(block_lines, #block_lines)
      table.remove(block_rows, #block_rows)
      removed = removed + 1
    end

    local data_row_idx = 0
    for i, line in ipairs(block_lines) do
      local drop = false
      local reason = nil

      if is_comma_only_line(line) then
        local expected = nil
        if sig_rows and sig_rows[data_row_idx + 1] then
          expected = #sig_rows[data_row_idx + 1]
        end
        if expected and expected > 1 then
          drop = false
          data_row_idx = data_row_idx + 1
        else
          drop = true
          reason = "comma-only"
        end
      else
        if not is_meta_row(line) then
          data_row_idx = data_row_idx + 1
        end
      end

      if drop then
        removed = removed + 1
        entries[#entries + 1] = { row = block_rows[i], line = line, reason = reason or "?" }
      else
        out[#out + 1] = line
      end
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  return removed, entries
end

local function split_keyword_blocks_with_unknown(lines)
  local blocks = {}
  local start_row, keyword = nil, nil
  for i, raw in ipairs(lines or {}) do
    local t = trim(strip_number_prefix(raw or ""))
    local kw = t:match("^(%*[%w_%-]+)")
    if kw then
      if start_row then
        blocks[#blocks + 1] = {
          keyword = keyword,
          start_row = start_row,
          end_row = i - 1,
        }
      end
      start_row = i
      keyword = kw
    end
  end
  if start_row then
    blocks[#blocks + 1] = {
      keyword = keyword,
      start_row = start_row,
      end_row = #lines,
    }
  end
  return blocks
end

local function advanced_clear_current_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = split_keyword_blocks_with_unknown(lines)
  if #blocks == 0 then
    return 0, {}
  end

  local out = {}
  local removed = 0
  local entries = {}

  -- Preamble: blank/comment lines before the first keyword block
  for r = 1, blocks[1].start_row - 1 do
    local line = lines[r] or ""
    if is_comment_line(line) or is_blank_line(line) then
      removed = removed + 1
      entries[#entries + 1] = { row = r, line = line, reason = is_comment_line(line) and "comment" or "blank" }
    else
      out[#out + 1] = line
    end
  end

  for _, b in ipairs(blocks) do
    local keyword_upper = b.keyword:upper()
    if store.get_keyword(keyword_upper) or keyword_upper:match("^%*MAT_") then
      local block_lines = {}
      local block_rows = {}
      for r = b.start_row, b.end_row do
        local line = lines[r] or ""
        if not is_comment_line(line) then
          block_lines[#block_lines + 1] = line
          block_rows[#block_rows + 1] = r
        else
          removed = removed + 1
          entries[#entries + 1] = { row = r, line = line, reason = "comment", keyword = keyword_upper }
        end
      end

      while #block_lines > 0 and is_blank_line(block_lines[1] or "") do
        entries[#entries + 1] = { row = block_rows[1], line = block_lines[1], reason = "leading-blank", keyword = keyword_upper }
        table.remove(block_lines, 1)
        table.remove(block_rows, 1)
        removed = removed + 1
      end
      while #block_lines > 0 and is_blank_line(block_lines[#block_lines] or "") do
        entries[#entries + 1] = { row = block_rows[#block_rows], line = block_lines[#block_lines], reason = "trailing-blank", keyword = keyword_upper }
        table.remove(block_lines, #block_lines)
        table.remove(block_rows, #block_rows)
        removed = removed + 1
      end

      -- Normalize keyword line to uppercase
      if #block_lines > 0 then
        block_lines[1] = block_lines[1]:gsub(vim.pesc(b.keyword), keyword_upper)
      end

      for _, line in ipairs(block_lines) do
        out[#out + 1] = line
      end
    else
      entries[#entries + 1] = {
        row = b.start_row,
        line = lines[b.start_row] or "",
        reason = "unknown-block",
        keyword = b.keyword,
        count = b.end_row - b.start_row + 1,
      }
      removed = removed + (b.end_row - b.start_row + 1)
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  return removed, entries
end

-- Split a parameter definition line into (indent, lhs, rhs, desc).
-- Desc is the part after the LAST comma (typically a quoted description).
-- Returns nil if the line is not a parameter definition.
local function split_param_line(line)
  local indent, lhs, rest = line:match("^(%s*)(%%?[%a_][%w_]*)%s*=%s*(.-)%s*$")
  if not lhs then
    return nil
  end

  -- Search from right to left for the last ", \"desc\"" pattern
  local desc_start = nil
  for pos = #rest - 1, 1, -1 do
    if rest:sub(pos):match('^,%s*"[^"]*"%s*$') then
      desc_start = pos
      break
    end
  end

  if desc_start then
    local rhs = trim(rest:sub(1, desc_start - 1))
    local desc = trim(rest:sub(desc_start + 1))  -- drop the comma itself
    return indent, lhs, rhs, desc
  end

  -- Fallback: plain comma (no quotes) — use the LAST comma to avoid
  -- splitting expressions like crv(1, x)
  local last_comma = nil
  for pos = #rest, 1, -1 do
    if rest:sub(pos, pos) == "," then
      last_comma = pos
      break
    end
  end
  if last_comma then
    local rhs = trim(rest:sub(1, last_comma - 1))
    local desc = trim(rest:sub(last_comma + 1))
    if desc ~= "" then
      return indent, lhs, rhs, desc
    end
  end

  return indent, lhs, trim(rest), nil
end

local function format_parameter_definition_lines(block_lines)
  local specs = {}
  local max_lhs = 0

  for i, line in ipairs(block_lines or {}) do
    local indent, lhs, rhs, desc = split_param_line(line)
    if lhs and rhs and rhs ~= "" then
      specs[i] = {
        indent = indent or "",
        lhs = lhs,
        rhs = rhs,
        desc = desc,
      }
      max_lhs = math.max(max_lhs, #lhs)
    end
  end

  if max_lhs == 0 then
    return block_lines
  end

  -- Compute max_prefix_len: the longest visual length from indent to the
  -- comma (inclusive) so that all opening quotes line up in the same column.
  local max_prefix_len = 0
  for _, spec in pairs(specs) do
    if spec.desc then
      local lhs_pad_len = math.max(1, max_lhs - #spec.lhs + 1)
      -- indent + lhs + lhs_pad + "= " + rhs + ","
      local prefix_len = #spec.indent + #spec.lhs + lhs_pad_len + 2 + #spec.rhs + 1
      max_prefix_len = math.max(max_prefix_len, prefix_len)
    end
  end

  local out = {}
  for i, line in ipairs(block_lines or {}) do
    local spec = specs[i]
    if not spec then
      out[#out + 1] = line
    else
      local lhs_pad = string.rep(" ", math.max(1, max_lhs - #spec.lhs + 1))
      local text = spec.indent .. spec.lhs .. lhs_pad .. "= " .. spec.rhs
      if spec.desc then
        local prefix_len = #spec.indent + #spec.lhs + #lhs_pad + 2 + #spec.rhs + 1
        local spaces_needed = max_prefix_len - prefix_len + 1
        if spaces_needed < 1 then
          spaces_needed = 1
        end
        text = text .. "," .. string.rep(" ", spaces_needed) .. spec.desc
      end
      out[#out + 1] = text
    end
  end
  return out
end

local function split_csv_keep_empty(line)
  local out = {}
  local s = (line or "") .. ","
  for part in s:gmatch("(.-),") do
    out[#out + 1] = part
  end
  return out
end

local function format_curve_data_lines(block_lines)
  -- Align multi-column data rows.
  -- Signed numbers (+/-) are split into a sign column and a numeric column,
  -- so digits align regardless of sign presence.
  local data_specs = {}
  local max_widths = {}       -- max numeric width per column
  local column_has_sign = {}  -- true if any field in this column has a leading sign

  for i, line in ipairs(block_lines) do
    if (line or ""):find(",") then
      local fields = split_csv_keep_empty(line)
      if #fields >= 2 then
        local cols = {}
        local signs = {}
        local num_parts = {}
        local has_content = false
        for ci = 1, #fields do
          local c = trim(fields[ci])
          cols[ci] = c
          if c ~= "" then
            has_content = true
            if c:match("^[+-]%d") or c:match("^[+-]%.%d") then
              signs[ci] = c:sub(1, 1)
              num_parts[ci] = c:sub(2)
              column_has_sign[ci] = true
            else
              signs[ci] = ""
              num_parts[ci] = c
            end
          end
        end
        if has_content then
          local widths = {}
          for ci = 1, #cols do
            local w = vim.fn.strdisplaywidth(num_parts[ci] or "")
            widths[ci] = w
            max_widths[ci] = math.max(max_widths[ci] or 0, w)
          end
          data_specs[i] = { cols = cols, signs = signs, num_parts = num_parts, widths = widths }
        end
      end
    end
  end

  if not next(max_widths) then
    return block_lines
  end

  local function format_field(ci, spec)
    local sign = spec.signs[ci] or ""
    local num = spec.num_parts[ci] or spec.cols[ci] or ""
    if column_has_sign[ci] then
      return (sign ~= "" and sign or " ") .. num
    end
    return num
  end

  local out = {}
  for i, line in ipairs(block_lines) do
    local spec = data_specs[i]
    if not spec then
      out[#out + 1] = line
    else
      local text = format_field(1, spec)
      local total_w_1 = column_has_sign[1] and (1 + (spec.widths[1] or 0)) or (spec.widths[1] or 0)
      for ci = 2, #spec.cols do
        local prev_max = max_widths[ci - 1] or 0
        local prev_total = column_has_sign[ci - 1] and (1 + prev_max) or prev_max
        local prev_w = spec.widths[ci - 1] or 0
        local prev_total_w = column_has_sign[ci - 1] and (1 + prev_w) or prev_w
        local pad = string.rep(" ", math.max(0, prev_total - prev_total_w))
        text = text .. ", " .. pad .. format_field(ci, spec)
      end
      out[#out + 1] = text
    end
  end
  return out
end

local function normalize_comma_lines(block_lines)
  local out = {}
  for _, line in ipairs(block_lines or {}) do
    local t = trim(line)
    if t == "" or t:sub(1, 1) == "#" or t:sub(1, 1) == "$" then
      out[#out + 1] = line
    else
      local fields = split_csv_keep_empty(line)
      if #fields > 1 then
        local lead = line:match("^(%s*)") or ""
        local text = trim(fields[1])
        for i = 2, #fields do
          text = text .. ", " .. trim(fields[i])
        end
        -- If first field was empty: ensure exactly one space before the
        -- leading comma; discard the original lead to avoid stacking spaces.
        if trim(fields[1]) == "" then
          out[#out + 1] = " " .. text
        else
          out[#out + 1] = lead .. text
        end
      else
        out[#out + 1] = line
      end
    end
  end
  return out
end

local function normalize_expression_lines(block_lines)
  local out = {}
  for _, line in ipairs(block_lines or {}) do
    local t = trim(line)
    if t == "" or t:sub(1, 1) == "#" or t:sub(1, 1) == "$" then
      out[#out + 1] = line
    else
      local lead = line:match("^(%s*)") or ""
      -- Step 1: remove spaces around ^
      local text = t:gsub("%s*%^%s*", "^")
      -- Step 2: remove spaces around + - * /
      -- Protect quoted strings
      local parts = {}
      local qi = 1
      while true do
        local qs, qe = text:find('"', qi)
        if not qs then
          parts[#parts + 1] = { type = "text", value = text:sub(qi) }
          break
        end
        parts[#parts + 1] = { type = "text", value = text:sub(qi, qs - 1) }
        local qe2 = text:find('"', qe + 1)
        if not qe2 then
          parts[#parts + 1] = { type = "quote", value = text:sub(qs) }
          break
        end
        parts[#parts + 1] = { type = "quote", value = text:sub(qs, qe2) }
        qi = qe2 + 1
      end
      for _, p in ipairs(parts) do
        if p.type == "text" then
          local v = p.value
          -- Remove spaces around + - * /
          v = v:gsub("%s*([%+%-%*/])%s*", "%1")
          p.value = v
        end
      end
      local result = ""
      for _, p in ipairs(parts) do
        result = result .. p.value
      end
      out[#out + 1] = lead .. result
    end
  end
  return out
end

local function simple_beautify_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = split_keyword_blocks(lines)
  if #blocks == 0 then
    return 0, {}
  end

  local changed = 0
  local entries = {}

  for _, b in ipairs(blocks) do
    local kw_upper = b.keyword:upper()
    local block_lines = {}
    for r = b.start_row + 1, b.end_row do
      block_lines[#block_lines + 1] = lines[r] or ""
    end

    local formatted = nil
    if kw_upper == "*PARAMETER" or kw_upper == "*PARAMETER_DEFAULT" then
      -- 双引号对齐优先：先规范化表达式运算符（避免对齐后 rhs 长度变化），
      -- 再对齐 name = value, "desc"
      formatted = normalize_expression_lines(block_lines)
      formatted = format_parameter_definition_lines(formatted)
    elseif kw_upper == "*CURVE" or kw_upper == "*TABLE" or kw_upper == "*PATH"
        or kw_upper == "*NODE" or kw_upper:match("^%*ELEMENT") then
      -- 列对齐优先：不对齐后再用 normalize_comma_lines 破坏列宽
      formatted = format_curve_data_lines(block_lines)
    elseif kw_upper == "*FUNCTION" then
      -- 表达式规范化（逗号在函数调用括号内，不能用简单 CSV split 处理）
      formatted = normalize_expression_lines(block_lines)
    else
      -- 其他一般关键字：逗号后一个空格 + 表达式运算符规范化
      formatted = normalize_comma_lines(block_lines)
      formatted = normalize_expression_lines(formatted)
    end

    if formatted then
      for idx, new_line in ipairs(formatted) do
        local row = b.start_row + idx
        local old_line = lines[row]
        if old_line ~= new_line then
          lines[row] = new_line
          changed = changed + 1
          entries[#entries + 1] = { row = row, keyword = b.keyword, old_line = old_line, new_line = new_line }
        end
      end
    end
  end

  if changed > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  return changed, entries
end

local function align_parameter_blocks_in_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = split_keyword_blocks(lines)
  if #blocks == 0 then
    return 0, {}
  end

  local changed = 0
  local entries = {}
  for _, b in ipairs(blocks) do
    local kw_upper = b.keyword:upper()
    local block_lines = {}
    for r = b.start_row + 1, b.end_row do
      block_lines[#block_lines + 1] = lines[r] or ""
    end

    local formatted = nil
    if b.keyword == "*PARAMETER" or b.keyword == "*PARAMETER_DEFAULT" then
      formatted = format_parameter_definition_lines(block_lines)
    elseif kw_upper == "*OBJECT" then
      local param_start = nil
      for li, line in ipairs(block_lines) do
        if line:match("^%s*%%?[%a_][%w_]+%s*=") then
          param_start = li
          break
        end
      end
      if param_start then
        local param_lines = {}
        for li = param_start, #block_lines do
          param_lines[#param_lines + 1] = block_lines[li]
        end
        local formatted_params = format_parameter_definition_lines(param_lines)
        formatted = {}
        for li = 1, param_start - 1 do
          formatted[li] = block_lines[li]
        end
        for li, l in ipairs(formatted_params) do
          formatted[param_start + li - 1] = l
        end
      end
    elseif kw_upper == "*CURVE" or kw_upper == "*TABLE" or kw_upper == "*PATH" then
      formatted = format_curve_data_lines(block_lines)
    end

    if formatted then
      for idx, new_line in ipairs(formatted) do
        local row = b.start_row + idx
        local old_line = lines[row]
        if old_line ~= new_line then
          lines[row] = new_line
          changed = changed + 1
          entries[#entries + 1] = {
            row = row,
            keyword = b.keyword,
            old_line = old_line,
            new_line = new_line,
          }
        end
      end
    end
  end

  if changed > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  return changed, entries
end

-- Legacy helpers: kept for backward compatibility; use log.append() directly.
local function current_operation_log_path()
  return log.log_path(), vim.fn.expand("%:p")
end

local function append_operation_log(operation, details)
  return log.append(operation, details)
end

local function parse_assignments_from_line(line)
  local t = strip_number_prefix(line or "")
  t = trim((t:gsub("%s[#$].*$", "")))
  if t == "" then
    return {}
  end
  -- Skip control-flow meta rows (~if, ~else, ~endif, etc.)
  if t:sub(1, 1) == "~" then
    return {}
  end

  local found = {}
  local search = 1
  while search <= #t do
    local s, e, name = t:find("%%?([%a_][%w_]*)%s*=", search)
    if not s then
      break
    end
    found[#found + 1] = { s = s, e = e, name = name }
    search = e + 1
  end
  if #found == 0 then
    return {}
  end

  local out = {}
  for i, it in ipairs(found) do
    local val_start = it.e + 1
    local val_end = (found[i + 1] and (found[i + 1].s - 1)) or #t
    local value = trim(t:sub(val_start, val_end))
    if found[i + 1] then
      -- Multiple assignments on the same line: comma is the separator
      value = trim((value:match("^([^,]+)") or value))
    else
      -- Single assignment: strip trailing description string
      -- but preserve commas inside function arguments like min(1, 2).
      local desc_pos = value:find(',%s*".*"$')
      if desc_pos then
        value = trim(value:sub(1, desc_pos - 1))
      end
    end
    if value ~= "" then
      out[#out + 1] = { name = it.name, value = value }
    end
  end
  return out
end

local function normalize_minus_variants(s)
  local t = s or ""
  t = t:gsub(vim.fn.nr2char(0x2212), "-")
  t = t:gsub(vim.fn.nr2char(0x2013), "-")
  t = t:gsub(vim.fn.nr2char(0x2014), "-")
  return t
end

local function parse_include_path_from_lines(lines, include_row, end_row)
  for r = include_row + 1, end_row do
    local raw = trim(lines[r] or "")
    if raw ~= "" and raw:sub(1, 1) ~= "#" and raw:sub(1, 1) ~= "$" then
      local q = raw:match('"(.-)"')
      if q and q ~= "" then
        return trim(q)
      end
      local first = trim((raw:match("^([^,%s]+)") or raw))
      if first ~= "" then
        return first
      end
      break
    end
  end
  return nil
end

local function resolve_include_path(base_file, rel)
  local r = trim(rel or "")
  if r == "" then
    return nil
  end
  r = r:gsub("\\", "/")
  if r:match("^[A-Za-z]:/") or r:match("^/") then
    return vim.fn.fnamemodify(r, ":p")
  end
  local base_dir = vim.fn.fnamemodify(base_file, ":p:h")
  return vim.fn.fnamemodify(base_dir .. "/" .. r, ":p")
end

local function read_lines_for_path(path)
  local p = trim(path or "")
  if p == "" or vim.fn.filereadable(p) ~= 1 then
    return nil
  end
  return vim.fn.readfile(p)
end

local function build_param_tables(lines, file_path, visited)
  local blocks = split_keyword_blocks(lines)
  local defaults = {}
  local params = {}
  visited = visited or {}
  local abs = file_path and vim.fn.fnamemodify(file_path, ":p") or nil
  if abs and visited[abs] then
    local merged = vim.tbl_extend("force", defaults, params)
    return merged, blocks
  end
  if abs then
    visited[abs] = true
  end
  for _, b in ipairs(blocks) do
    local ku = (b.keyword or ""):upper()
    if ku == "*PARAMETER" or ku == "*PARAMETER_DEFAULT" then
      for r = b.start_row + 1, b.end_row do
        for _, a in ipairs(parse_assignments_from_line(lines[r] or "")) do
          if ku == "*PARAMETER" then
            params[a.name] = a.value
          else
            defaults[a.name] = a.value
          end
        end
      end
    elseif ku == "*INCLUDE" and abs then
      local rel = parse_include_path_from_lines(lines, b.start_row, b.end_row)
      local full = resolve_include_path(abs, rel)
      local child_lines = read_lines_for_path(full)
      if child_lines then
        local child_vars = build_param_tables(child_lines, full, visited)
        defaults = vim.tbl_extend("force", defaults, child_vars)
      end
    end
  end
  local merged = vim.tbl_extend("force", defaults, params) -- PARAMETER overrides DEFAULT
  if abs then
    visited[abs] = nil
  end
  return merged, blocks
end

local eval_cache_fast = {}
local eval_cache_func = {}
local current_eval_error = nil

-- Round near-zero and near-integer values for cleaner output.
-- Prevents cos(90°) → 6.123e-17 and -0 → -0.
local function clean_numeric_result(v)
  if type(v) ~= "number" then
    return v
  end
  local eps = 1e-10
  if math.abs(v) < eps then
    return "0"
  end
  local rounded = math.floor(v + 0.5)
  if math.abs(v - rounded) < eps then
    return tostring(rounded)
  end
  local rounded_neg = math.ceil(v - 0.5)
  if math.abs(v - rounded_neg) < eps then
    return tostring(rounded_neg)
  end
  return nil
end

-- Fast recursive-descent evaluator for simple arithmetic expressions.
-- Replaces load()/pcall() which is very slow when called thousands of times.
local function eval_expr_fast(expr)
  current_eval_error = nil
  local src = trim(expr or "")
  if src == "" then
    return nil
  end

  local cached = eval_cache_fast[src]
  if cached ~= nil then
    if type(cached) == "table" then
      if not cached.ok then
        current_eval_error = cached.error or nil
        return nil
      end
      return cached.value
    end
    -- backward compatibility
    return cached == false and nil or cached
  end

  -- Quick reject: only digits, operators, parens, dot, e/E, whitespace
  if src:find("[^%d%+%-%*%/%^%(%)%.eE%s]") then
    eval_cache_fast[src] = { ok = false, error = current_eval_error }
    return nil
  end

  local s = src
  local pos = 1
  local len = #s

  local function skip_ws()
    while pos <= len and s:sub(pos, pos):match("%s") do
      pos = pos + 1
    end
  end

  local function parse_number()
    skip_ws()
    local start = pos
    while pos <= len and s:sub(pos, pos):match("[%d%.]") do
      pos = pos + 1
    end
    if pos > start then
      if pos <= len and s:sub(pos, pos):match("[eE]") then
        local ep = pos
        pos = pos + 1
        if pos <= len and s:sub(pos, pos):match("[+-]") then
          pos = pos + 1
        end
        local exp_start = pos
        while pos <= len and s:sub(pos, pos):match("%d") do
          pos = pos + 1
        end
        if pos == exp_start then
          pos = ep
        end
      end
      local n = tonumber(s:sub(start, pos - 1))
      if n then return n end
    end
    pos = start
    return nil
  end

  -- Pre-declare mutually recursive parsers so they refer to locals, not globals.
  local parse_expr, parse_term, parse_power, parse_factor

  parse_factor = function()
    skip_ws()
    local ch = s:sub(pos, pos)
    if ch == "(" then
      pos = pos + 1
      local v = parse_expr()
      skip_ws()
      if pos <= len and s:sub(pos, pos) == ")" then
        pos = pos + 1
      end
      return v
    elseif ch == "-" then
      pos = pos + 1
      local v = parse_factor()
      if v == nil then return nil end
      return -v
    elseif ch == "+" then
      pos = pos + 1
      local v = parse_factor()
      if v == nil then return nil end
      return v
    else
      return parse_number()
    end
  end

  parse_power = function()
    local left = parse_factor()
    if not left then return nil end
    skip_ws()
    while pos <= len and s:sub(pos, pos) == "^" do
      pos = pos + 1
      local right = parse_factor()
      if not right then return nil end
      if left == 0 and right < 0 then
        current_eval_error = "Zero raised to negative power in '" .. src .. "'"
        eval_cache_fast[src] = false
        return nil
      end
      left = left ^ right
      skip_ws()
    end
    return left
  end

  parse_term = function()
    local left = parse_power()
    if not left then return nil end
    skip_ws()
    while true do
      local ch = s:sub(pos, pos)
      if ch == "*" then
        pos = pos + 1
        local right = parse_power()
        if not right then return nil end
        left = left * right
      elseif ch == "/" then
        pos = pos + 1
        local right = parse_power()
        if not right then return nil end
        if right == 0 then
          current_eval_error = "Division by zero in '" .. src .. "'"
          eval_cache_fast[src] = false
          return nil
        end
        left = left / right
      else
        break
      end
      skip_ws()
    end
    return left
  end

  parse_expr = function()
    local left = parse_term()
    if not left then return nil end
    skip_ws()
    while true do
      local ch = s:sub(pos, pos)
      if ch == "+" then
        pos = pos + 1
        local right = parse_term()
        if not right then return nil end
        left = left + right
      elseif ch == "-" then
        pos = pos + 1
        local right = parse_term()
        if not right then return nil end
        left = left - right
      else
        break
      end
      skip_ws()
    end
    return left
  end

  local result = parse_expr()
  skip_ws()
  if pos <= len or not result then
    eval_cache_fast[src] = { ok = false, error = current_eval_error }
    return nil
  end

  if result ~= result then
    current_eval_error = "Result is NaN in '" .. src .. "'"
    eval_cache_fast[src] = { ok = false, error = current_eval_error }
    return nil
  end
  if result == math.huge or result == -math.huge then
    current_eval_error = "Result is infinite in '" .. src .. "'"
    eval_cache_fast[src] = { ok = false, error = current_eval_error }
    return nil
  end

  local cleaned = clean_numeric_result(result)
  if cleaned then
    eval_cache_fast[src] = { ok = true, value = cleaned }
    return cleaned
  end

  local abs_v = math.abs(result)
  local prefer_sci = src:find("%d[eE][+-]?%d") ~= nil
    or (abs_v ~= 0 and (abs_v >= 1e6 or abs_v < 1e-4))
  local out
  if prefer_sci then
    local s_num = string.format("%.8e", result)
    local mant, exp = s_num:match("^(.-)e([%+%-]%d+)$")
    if mant and exp then
      mant = mant:gsub("(%..-)0+$", "%1")
      mant = mant:gsub("%.$", "")
      exp = exp:gsub("%+","")
      exp = exp:gsub("^(-?)0+(%d)", "%1%2")
      if exp == "" then exp = "0" end
      out = mant .. "e" .. exp
    else
      out = s_num
    end
  else
    out = string.format("%.15g", result)
  end

  eval_cache_fast[src] = { ok = true, value = out }
  return out
end

-- Extended evaluator supporting intrinsic math functions (sin, cos, H, min, max, etc.).
-- Used by re -b to compute final numeric values.
local MATH_FUNCS = {
  sin = function(x) return math.sin(math.rad(x)) end,
  cos = function(x) return math.cos(math.rad(x)) end,
  tan = function(x) return math.tan(math.rad(x)) end,
  asin = function(x) return math.deg(math.asin(x)) end,
  atan = function(x) return math.deg(math.atan(x)) end,
  tanh = math.tanh,
  sinr = math.sin,
  cosr = math.cos,
  tanr = math.tan,
  asinr = math.asin,
  acosr = math.acos,
  atanr = math.atan,
  exp = math.exp,
  ln = math.log,
  log = math.log,
  log10 = math.log10,
  sqrt = math.sqrt,
  abs = math.abs,
  sign = function(x) return x < 0 and -1 or 1 end,
  floor = math.floor,
  ceil = math.ceil,
  round = function(x) return math.floor(x + 0.5) end,
  mod = function(a, b) return a % b end,
  d = function(i, j) return i == j and 1 or 0 end,
  h = function(x) return x >= 0 and 1 or 0 end,
  min = function(...) return math.min(...) end,
  max = function(...) return math.max(...) end,
  erf = function(x)
    local a1, a2, a3, a4, a5 = 0.254829592, -0.284496736, 1.421413741, -1.453152027, 1.061405429
    local p = 0.3275911
    local sgn = x < 0 and -1 or 1
    x = math.abs(x)
    local t = 1 / (1 + p * x)
    local y = 1 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * math.exp(-x * x)
    return sgn * y
  end,
}

local CONSTANTS = {
  pi = math.pi,
}

local function eval_expr_with_functions(expr)
  current_eval_error = nil
  local src = trim(expr or "")
  if src == "" then
    return nil
  end

  local cached = eval_cache_func[src]
  if cached ~= nil then
    if type(cached) == "table" then
      if not cached.ok then
        current_eval_error = cached.error or nil
        return nil
      end
      return cached.value
    end
    -- backward compatibility
    return cached == false and nil or cached
  end

  -- Skip quoted strings (e.g. descriptions inside *PARAMETER rows)
  if src:match('^".*"$') then
    return nil
  end

  -- Skip keyword headers and plain identifiers (enum values like P, SI, CFD)
  if src:match("^%*") or not src:find("[%d%+%-%*/%^%(%)%[%].]") then
    return nil
  end

  local s = src
  local pos = 1
  local len = #s

  local function skip_ws()
    while pos <= len and s:sub(pos, pos):match("%s") do
      pos = pos + 1
    end
  end

  local function parse_number()
    skip_ws()
    local start = pos
    while pos <= len and s:sub(pos, pos):match("[%d%.]") do
      pos = pos + 1
    end
    if pos > start then
      if pos <= len and s:sub(pos, pos):match("[eE]") then
        local ep = pos
        pos = pos + 1
        if pos <= len and s:sub(pos, pos):match("[+-]") then
          pos = pos + 1
        end
        local exp_start = pos
        while pos <= len and s:sub(pos, pos):match("%d") do
          pos = pos + 1
        end
        if pos == exp_start then
          pos = ep
        end
      end
      local n = tonumber(s:sub(start, pos - 1))
      if n then return n end
    end
    pos = start
    return nil
  end

  local function parse_identifier()
    skip_ws()
    local start = pos
    if pos <= len and s:sub(pos, pos):match("[%a_]") then
      pos = pos + 1
      while pos <= len and s:sub(pos, pos):match("[%w_]") do
        pos = pos + 1
      end
      return s:sub(start, pos - 1)
    end
    return nil
  end

  local parse_expr, parse_term, parse_power, parse_factor

  local function parse_argument_list()
    skip_ws()
    if pos > len or s:sub(pos, pos) ~= "(" then
      return nil
    end
    pos = pos + 1
    local args = {}
    skip_ws()
    if pos <= len and s:sub(pos, pos) == ")" then
      pos = pos + 1
      return args
    end
    while true do
      local v = parse_expr()
      if v == nil then return nil end
      args[#args + 1] = v
      skip_ws()
      if pos > len then return nil end
      local ch = s:sub(pos, pos)
      if ch == ")" then
        pos = pos + 1
        return args
      elseif ch == "," then
        pos = pos + 1
      else
        return nil
      end
    end
  end

  parse_factor = function()
    skip_ws()
    if pos > len then return nil end
    local ch = s:sub(pos, pos)
    if ch == "(" then
      pos = pos + 1
      local v = parse_expr()
      skip_ws()
      if pos <= len and s:sub(pos, pos) == ")" then
        pos = pos + 1
      end
      return v
    elseif ch == "-" then
      pos = pos + 1
      local v = parse_factor()
      if v == nil then return nil end
      return -v
    elseif ch == "+" then
      pos = pos + 1
      local v = parse_factor()
      if v == nil then return nil end
      return v
    elseif ch:match("[%d%.]") then
      return parse_number()
    elseif ch:match("[%a_]") then
      local id = parse_identifier()
      if not id then return nil end
      skip_ws()
      if pos <= len and s:sub(pos, pos) == "(" then
        local args = parse_argument_list()
        if args == nil then return nil end
        local fn = MATH_FUNCS[id:lower()]
        if fn then
          local fn_result = fn(unpack(args))
          if type(fn_result) == "number" then
            if fn_result ~= fn_result then
              current_eval_error = "Function result is NaN in '" .. src .. "'"
              eval_cache_func[src] = false
              return nil
            end
            if fn_result == math.huge or fn_result == -math.huge then
              current_eval_error = "Function result is infinite in '" .. src .. "'"
              eval_cache_func[src] = false
              return nil
            end
          end
          return fn_result
        else
          current_eval_error = "Unknown function or identifier '" .. id .. "' in '" .. src .. "'"
          eval_cache_func[src] = { ok = false, error = current_eval_error }
          return nil
        end
      else
        local c = CONSTANTS[id:lower()]
        if c then
          return c
        else
          current_eval_error = "Unknown identifier '" .. id .. "' in '" .. src .. "'"
          eval_cache_func[src] = { ok = false, error = current_eval_error }
          return nil
        end
      end
    else
      current_eval_error = "Unexpected character '" .. ch .. "' in '" .. src .. "'"
      eval_cache_func[src] = { ok = false, error = current_eval_error }
      return nil
    end
  end

  parse_power = function()
    local left = parse_factor()
    if not left then return nil end
    skip_ws()
    while pos <= len and s:sub(pos, pos) == "^" do
      pos = pos + 1
      local right = parse_factor()
      if not right then return nil end
      if left == 0 and right < 0 then
        current_eval_error = "Zero raised to negative power in '" .. src .. "'"
        eval_cache_func[src] = false
        return nil
      end
      left = left ^ right
      skip_ws()
    end
    return left
  end

  parse_term = function()
    local left = parse_power()
    if not left then return nil end
    skip_ws()
    while true do
      local ch = s:sub(pos, pos)
      if ch == "*" then
        pos = pos + 1
        local right = parse_power()
        if not right then return nil end
        left = left * right
      elseif ch == "/" then
        pos = pos + 1
        local right = parse_power()
        if not right then return nil end
        if right == 0 then
          current_eval_error = "Division by zero in '" .. src .. "'"
          eval_cache_func[src] = false
          return nil
        end
        left = left / right
      else
        break
      end
      skip_ws()
    end
    return left
  end

  parse_expr = function()
    local left = parse_term()
    if not left then return nil end
    skip_ws()
    while true do
      local ch = s:sub(pos, pos)
      if ch == "+" then
        pos = pos + 1
        local right = parse_term()
        if not right then return nil end
        left = left + right
      elseif ch == "-" then
        pos = pos + 1
        local right = parse_term()
        if not right then return nil end
        left = left - right
      else
        break
      end
      skip_ws()
    end
    return left
  end

  local result = parse_expr()
  skip_ws()
  if pos <= len or result == nil then
    eval_cache_func[src] = { ok = false, error = current_eval_error }
    return nil
  end

  if result ~= result then
    current_eval_error = "Result is NaN in '" .. src .. "'"
    eval_cache_func[src] = { ok = false, error = current_eval_error }
    return nil
  end
  if result == math.huge or result == -math.huge then
    current_eval_error = "Result is infinite in '" .. src .. "'"
    eval_cache_func[src] = { ok = false, error = current_eval_error }
    return nil
  end

  local cleaned = clean_numeric_result(result)
  if cleaned then
    eval_cache_func[src] = { ok = true, value = cleaned }
    return cleaned
  end

  local abs_v = math.abs(result)
  local prefer_sci = src:find("%d[eE][+-]?%d") ~= nil
    or (abs_v ~= 0 and (abs_v >= 1e6 or abs_v < 1e-4))
  local out
  if prefer_sci then
    local s_num = string.format("%.8e", result)
    local mant, exp = s_num:match("^(.-)e([%+%-]%d+)$")
    if mant and exp then
      mant = mant:gsub("(%..-)0+$", "%1")
      mant = mant:gsub("%.$", "")
      exp = exp:gsub("%+","")
      exp = exp:gsub("^(-?)0+(%d)", "%1%2")
      if exp == "" then exp = "0" end
      out = mant .. "e" .. exp
    else
      out = s_num
    end
  else
    out = string.format("%.15g", result)
  end

  eval_cache_func[src] = { ok = true, value = out }
  return out
end

-- Partial evaluator: simplifies numeric sub-expressions while preserving
-- unknown identifiers (e.g. loop variables r1, r2).
-- Returns a number if fully evaluable, a string if partially evaluable, nil on error.
local function partial_eval_expr(expr)
  local src = trim(expr or "")
  if src == "" then return nil end
  if src:match('^".*"$') then return nil end
  if src:match("^%*") or not src:find("[%d%+%-%*/%^%(%)%[%].]") then return nil end

  local s = src
  local pos = 1
  local len = #s

  local function skip_ws()
    while pos <= len and s:sub(pos, pos):match("%s") do pos = pos + 1 end
  end

  local function parse_number()
    skip_ws()
    local start = pos
    while pos <= len and s:sub(pos, pos):match("[%d%.]") do pos = pos + 1 end
    if pos > start then
      if pos <= len and s:sub(pos, pos):match("[eE]") then
        local ep = pos
        pos = pos + 1
        if pos <= len and s:sub(pos, pos):match("[+-]") then pos = pos + 1 end
        local exp_start = pos
        while pos <= len and s:sub(pos, pos):match("%d") do pos = pos + 1 end
        if pos == exp_start then pos = ep end
      end
      local n = tonumber(s:sub(start, pos - 1))
      if n then return n end
    end
    pos = start
    return nil
  end

  local function parse_identifier()
    skip_ws()
    local start = pos
    if pos <= len and s:sub(pos, pos):match("[%a_]") then
      pos = pos + 1
      while pos <= len and s:sub(pos, pos):match("[%w_]") do pos = pos + 1 end
      return s:sub(start, pos - 1)
    end
    return nil
  end

  local parse_expr, parse_term, parse_power, parse_factor

  local function parse_argument_list()
    skip_ws()
    if pos > len or s:sub(pos, pos) ~= "(" then return nil end
    pos = pos + 1
    local args = {}
    skip_ws()
    if pos <= len and s:sub(pos, pos) == ")" then
      pos = pos + 1
      return args
    end
    while true do
      local v = parse_expr()
      if v == nil then return nil end
      args[#args + 1] = v
      skip_ws()
      if pos > len then return nil end
      local ch = s:sub(pos, pos)
      if ch == ")" then
        pos = pos + 1
        return args
      elseif ch == "," then
        pos = pos + 1
      else
        return nil
      end
    end
  end

  local function is_num(v) return type(v) == "number" end

  local function fmt_val(v)
    if is_num(v) then
      local cleaned = clean_numeric_result(v)
      if cleaned then return cleaned end
      return string.format("%.15g", v)
    end
    return tostring(v)
  end

  parse_factor = function()
    skip_ws()
    if pos > len then return nil end
    local ch = s:sub(pos, pos)
    if ch == "(" then
      pos = pos + 1
      local v = parse_expr()
      skip_ws()
      if pos <= len and s:sub(pos, pos) == ")" then pos = pos + 1 end
      if v == nil then return nil end
      if is_num(v) then return v end
      return "(" .. tostring(v) .. ")"
    elseif ch == "-" then
      pos = pos + 1
      local v = parse_factor()
      if v == nil then return nil end
      if is_num(v) then return -v end
      return "-" .. tostring(v)
    elseif ch == "+" then
      pos = pos + 1
      local v = parse_factor()
      if v == nil then return nil end
      return v
    elseif ch:match("[%d%.]") then
      return parse_number()
    elseif ch:match("[%a_]") then
      local id = parse_identifier()
      if not id then return nil end
      skip_ws()
      if pos <= len and s:sub(pos, pos) == "(" then
        local args = parse_argument_list()
        if args == nil then return nil end
        local fn = MATH_FUNCS[id:lower()]
        if fn then
          local all_num = true
          for _, a in ipairs(args) do
            if not is_num(a) then all_num = false; break end
          end
          if all_num then
            local fn_result = fn(unpack(args))
            if type(fn_result) == "number" then
              if fn_result ~= fn_result then return nil end
              if fn_result == math.huge or fn_result == -math.huge then return nil end
            end
            return fn_result
          else
            local parts = {}
            for _, a in ipairs(args) do
              parts[#parts + 1] = fmt_val(a)
            end
            return id .. "(" .. table.concat(parts, ",") .. ")"
          end
        else
          -- Unknown function (e.g. crv, fcn, dfcn): preserve as string
          local parts = {}
          for _, a in ipairs(args) do
            parts[#parts + 1] = fmt_val(a)
          end
          return id .. "(" .. table.concat(parts, ",") .. ")"
        end
      else
        local c = CONSTANTS[id:lower()]
        if c then return c end
        return id
      end
    else
      return nil
    end
  end

  parse_power = function()
    local left = parse_factor()
    if left == nil then return nil end
    skip_ws()
    while pos <= len and s:sub(pos, pos) == "^" do
      pos = pos + 1
      local right = parse_factor()
      if right == nil then return nil end
      if is_num(left) and is_num(right) then
        if left == 0 and right < 0 then return nil end
        left = left ^ right
      else
        left = fmt_val(left) .. "^" .. fmt_val(right)
      end
      skip_ws()
    end
    return left
  end

  parse_term = function()
    local left = parse_power()
    if left == nil then return nil end
    skip_ws()
    while true do
      local ch = s:sub(pos, pos)
      if ch == "*" then
        pos = pos + 1
        local right = parse_power()
        if right == nil then return nil end
        if is_num(left) and is_num(right) then
          left = left * right
        else
          left = fmt_val(left) .. "*" .. fmt_val(right)
        end
      elseif ch == "/" then
        pos = pos + 1
        local right = parse_power()
        if right == nil then return nil end
        if is_num(left) and is_num(right) then
          if right == 0 then return nil end
          left = left / right
        else
          left = fmt_val(left) .. "/" .. fmt_val(right)
        end
      else
        break
      end
      skip_ws()
    end
    return left
  end

  parse_expr = function()
    local left = parse_term()
    if left == nil then return nil end
    skip_ws()
    while true do
      local ch = s:sub(pos, pos)
      if ch == "+" then
        pos = pos + 1
        local right = parse_term()
        if right == nil then return nil end
        if is_num(left) and is_num(right) then
          left = left + right
        else
          left = fmt_val(left) .. "+" .. fmt_val(right)
        end
      elseif ch == "-" then
        pos = pos + 1
        local right = parse_term()
        if right == nil then return nil end
        if is_num(left) and is_num(right) then
          left = left - right
        else
          left = fmt_val(left) .. "-" .. fmt_val(right)
        end
      else
        break
      end
      skip_ws()
    end
    return left
  end

  local result = parse_expr()
  skip_ws()
  if pos <= len or result == nil then return nil end
  return result
end

-- Falls back to eval_expr_with_functions for expressions containing
-- function names (sin, cos, H, min, max, etc.) or constants (pi).
local function try_eval_numeric(expr)
  local prev_error = current_eval_error
  current_eval_error = nil
  local src = trim(expr or "")
  if src == "" then
    return nil
  end
  -- Skip Impetus intrinsic function calls (fcn, crv, dfcn) that have no
  -- Lua equivalent and should be preserved as-is.
  if src:find("fcn%(") or src:find("crv%(") or src:find("dfcn%(") then
    return nil
  end
  local result
  if src:find("[%a_]") then
    result = eval_expr_with_functions(expr)
  else
    result = eval_expr_fast(expr)
  end
  if not result and not current_eval_error then
    current_eval_error = prev_error
  end
  return result
end

local function is_plain_numeric_literal(expr)
  local src = trim(expr or "")
  if src == "" then
    return false
  end
  if tonumber(src) == nil then
    return false
  end
  return not src:find("[^%d%+%-%.eE]")
end

local function simplify_numeric_text(text)
  local s = text or ""
  local eval_errors = {}

  -- Special handling for control directives: simplify only the trailing expression
  -- e.g. ~repeat %a+1  →  ~repeat 12
  local directive, rest = trim(s):match("^(~%S+)%s+(.*)$")
  if directive and rest then
    if rest:find("[%d%+%-%*/%^%(%)%[%].]") then
      local num = try_eval_numeric(rest)
      if current_eval_error then
        current_eval_error = nil
      end
      if num then
        return directive .. " " .. num
      end
    end
    return s
  end

  -- Simplify bracket expressions
  s = s:gsub("%[([^%[%]]-)%]", function(expr)
    local num = try_eval_numeric(expr)
    if current_eval_error then
      table.insert(eval_errors, current_eval_error)
      current_eval_error = nil
    end
    if num then
      return num
    end
    return "[" .. expr .. "]"
  end)

  -- Simplify fields: split by comma (top-level only, skip commas inside parens),
  -- evaluate each non-literal field
  local fields = {}
  local any_changed = false
  local depth = 0
  local field_start = 1
  local function process_field(field)
    local ft = trim(field)
    if ft ~= "" and not is_plain_numeric_literal(ft) and not ft:match('^".*"$') and not ft:find("=")
       and not ft:match("^~") and ft:find("[%d%+%-%*/%^%(%)%[%].]") then
      local num = try_eval_numeric(ft)
      if current_eval_error then
        table.insert(eval_errors, current_eval_error)
        current_eval_error = nil
      end
      if num then
        local lead = field:match("^(%s*)")
        local trail = field:match("(%s*)$")
        fields[#fields + 1] = lead .. num .. trail
        any_changed = true
      else
        -- Fallback: partial simplification for expressions with unknown variables
        local simplified = partial_eval_expr(ft)
        if simplified and tostring(simplified) ~= ft then
          local lead = field:match("^(%s*)")
          local trail = field:match("(%s*)$")
          fields[#fields + 1] = lead .. tostring(simplified) .. trail
          any_changed = true
        else
          fields[#fields + 1] = field
        end
      end
    else
      fields[#fields + 1] = field
    end
  end
  for i = 1, #s do
    local ch = s:sub(i, i)
    if ch == "(" then
      depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
    elseif ch == "," and depth == 0 then
      process_field(s:sub(field_start, i - 1))
      field_start = i + 1
    end
  end
  process_field(s:sub(field_start))
  if any_changed then
    s = table.concat(fields, ",")
  end

  -- Simplify whole line if no commas
  local whole = trim(s)
  if whole ~= "" and whole:find(",", 1, true) == nil and not is_plain_numeric_literal(whole)
     and whole:find("[%d%+%-%*/%^%(%)%[%].]") then
    local num = try_eval_numeric(whole)
    if current_eval_error then
      table.insert(eval_errors, current_eval_error)
      current_eval_error = nil
    end
    if num then
      local lead = s:match("^(%s*)")
      local trail = s:match("(%s*)$")
      return lead .. num .. trail
    end
    -- Fallback: partial simplification for expressions with unknown variables
    local simplified = partial_eval_expr(whole)
    if simplified and tostring(simplified) ~= whole then
      local lead = s:match("^(%s*)")
      local trail = s:match("(%s*)$")
      return lead .. tostring(simplified) .. trail
    end
  end

  if #eval_errors > 0 then
    current_eval_error = eval_errors[1]
  end
  return s
end

local function simplify_numeric_text_fixed_point(text, max_passes)
  local s = text or ""
  local passes = max_passes or 4
  for _ = 1, passes do
    local next_s = simplify_numeric_text(s)
    if next_s == s then
      break
    end
    s = next_s
  end
  return s
end

local function refresh_buffer_analysis(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  -- nvim_buf_set_lines does not trigger TextChanged, so ref marks and lint
  -- won't auto-update. Force a refresh.
  analysis.invalidate_buffer_index(buf)
  lint.run(buf)
  require("impetus.ref_marks").update(buf)
end

-- ~repeat block expansion helpers for re -c --------------------------------

local function find_matching_end_repeat(lines, start_idx)
  local depth = 1
  for i = start_idx + 1, #lines do
    local t = trim(strip_number_prefix(lines[i] or ""))
    if t:match("^~repeat%f[%A]") then
      depth = depth + 1
    elseif t:match("^~end_repeat%f[%A]") then
      depth = depth - 1
      if depth == 0 then
        return i
      end
    end
  end
  return nil
end

-- Recursively expand a ~repeat block starting at start_idx.
-- loop_vars is a table like { r1 = 3, r2 = 7, ... }.
-- Returns (expanded_lines, end_idx) or (nil, nil) on error.
local function expand_repeat_block(lines, start_idx, loop_vars)
  loop_vars = loop_vars or {}
  local t = trim(strip_number_prefix(lines[start_idx] or ""))
  local repeat_count = t:match("^~repeat%s+(%d+)")
  if not repeat_count then
    return nil, nil
  end
  local count = tonumber(repeat_count)
  if not count or count <= 0 then
    return nil, nil
  end
  local match_end = find_matching_end_repeat(lines, start_idx)
  if not match_end then
    return nil, nil
  end

  local depth = 0
  for _ in pairs(loop_vars) do
    depth = depth + 1
  end
  local var_name = "r" .. (depth + 1)

  local result = {}
  for n = 1, count do
    local new_vars = vim.tbl_extend("force", {}, loop_vars)
    new_vars[var_name] = n
    local j = start_idx + 1
    while j < match_end do
      local line = lines[j]
      local inner_t = trim(strip_number_prefix(line or ""))
      local inner_count = inner_t:match("^~repeat%s+(%d+)")
      if inner_count then
        local inner_expanded, inner_end = expand_repeat_block(lines, j, new_vars)
        if inner_expanded then
          for _, nl in ipairs(inner_expanded) do
            table.insert(result, nl)
          end
          j = inner_end + 1
        else
          table.insert(result, line)
          j = j + 1
        end
      else
        -- Replace rN variables (safe: r1 won't match inside r10)
        local new_line = line
        new_line = new_line:gsub("r(%d+)", function(idx)
          local var = "r" .. idx
          if new_vars[var] ~= nil then
            return tostring(new_vars[var])
          end
          return "r" .. idx
        end)
        -- Strip leading indentation from ~repeat block nesting
        new_line = trim(new_line)
        -- Simplify numeric expressions in the generated line
        new_line = simplify_numeric_text_fixed_point(new_line, 4)
        table.insert(result, new_line)
        j = j + 1
      end
    end
  end
  return result, match_end
end

-- Expand all top-level ~repeat blocks in the buffer.
local function expand_all_repeats(lines)
  local result = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local t = trim(strip_number_prefix(line or ""))
    local repeat_count = t:match("^~repeat%s+(%d+)")
    if repeat_count then
      local expanded, match_end = expand_repeat_block(lines, i, {})
      if expanded then
        for _, nl in ipairs(expanded) do
          table.insert(result, nl)
        end
        i = match_end + 1
      else
        table.insert(result, line)
        i = i + 1
      end
    else
      table.insert(result, line)
      i = i + 1
    end
  end
  return result
end

local function replace_params_in_buffer(mode)
  mode = mode or "ref"
  local apply_arith = (mode == "arith" or mode == "all" or mode == "repeat")
  local replace_defs = (mode == "all")
  local expand_repeat = (mode == "repeat")
  local replace_defs = (mode == "all")
  local eval_fn = (mode == "all") and eval_expr_with_functions or try_eval_numeric
  local math_errors = {}
  local function collect_eval_error(row, expr)
    if current_eval_error then
      table.insert(math_errors, { row = row, expr = expr or "", reason = current_eval_error })
      current_eval_error = nil
    end
  end

  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local vars, blocks = build_param_tables(lines, vim.api.nvim_buf_get_name(buf))
  if vim.tbl_count(vars) == 0 and not apply_arith then
    return 0, {}
  end
  local entries = {}

  -- Mark parameter definition rows (*PARAMETER and *PARAMETER_DEFAULT)
  -- Skip meta rows (~if, ~else, ~endif) so they get %param substitution even inside *PARAMETER
  local row_in_param = {}
  for _, b in ipairs(blocks) do
    local ku = (b.keyword or ""):upper()
    if ku == "*PARAMETER" or ku == "*PARAMETER_DEFAULT" then
      for r = b.start_row, b.end_row do
        local t = trim(strip_number_prefix(lines[r] or ""))
        if t ~= "" and t:sub(1, 1) ~= "~" then
          row_in_param[r] = true
        end
      end
    end
  end

  -- Mark *INCLUDE block rows (file paths like material_fsp.k must not be
  -- treated as arithmetic expressions).
  local row_in_include = {}
  for _, b in ipairs(blocks) do
    local ku = (b.keyword or ""):upper()
    if ku == "*INCLUDE" then
      for r = b.start_row, b.end_row do
        row_in_include[r] = true
      end
    end
  end

  -- Mark *FUNCTION expression rows (row 2+ inside *FUNCTION blocks)
  -- These contain coordinate variables (x, y, z, t) and crv()/fcn() calls;
  -- arithmetic simplification must be skipped.
  -- Note: scan directly rather than relying on split_keyword_blocks,
  -- because *FUNCTION blocks may contain nested *TABLE / *END_TABLE.
  local function_expr_rows = {}
  local in_function = false
  local function_data_count = 0
  for r = 1, #lines do
    local t = trim(strip_number_prefix(lines[r] or ""))
    if t:match("^%*FUNCTION%f[%A]") then
      in_function = true
      function_data_count = 0
    elseif t:match("^%*END_FUNCTION%f[%A]") then
      in_function = false
      function_data_count = 0
    elseif in_function then
      -- Skip nested keyword rows (e.g. *TABLE, *END_TABLE) and comments
      if not t:match("^%*") and t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" and not t:match('^".*"$') then
        function_data_count = function_data_count + 1
        if function_data_count >= 2 then
          function_expr_rows[r] = true
        end
      end
    end
  end

  -- Mark rows inside ~repeat blocks (they contain loop variables r1, r2, etc.)
  local repeat_block_rows = {}
  local in_repeat = false
  for r = 1, #lines do
    local t = trim(strip_number_prefix(lines[r] or ""))
    if t:match("^~repeat%f[%A]") then
      in_repeat = true
    elseif t:match("^~end_repeat%f[%A]") then
      in_repeat = false
    elseif in_repeat then
      repeat_block_rows[r] = true
    end
  end

  -- Initialize current_vars with all known params (include-file params as base)
  local current_vars = {}
  for name, value in pairs(vars or {}) do
    current_vars[name] = value
  end

  -- Helper: recursively substitute %name references using current_vars.
  -- Detects circular references and aborts via cycle_detected flag.
  local cycle_detected = false
  local cycle_params = {}

  local function shallow_copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
  end

  local MAX_SUBST_LEN = 10000

  local function substitute_vars(text, depth, chain)
    if cycle_detected then return text end
    depth = depth or 0
    if depth > 15 then
      cycle_detected = true
      cycle_params["__depth_limit__"] = true
      return text
    end
    chain = chain or {}
    local s = text or ""
    -- Replace bracket expressions recursively
    s = s:gsub("%[([^%[%]]-)%]", function(expr)
      return substitute_vars(expr, depth + 1, shallow_copy(chain))
    end)
    if #s > MAX_SUBST_LEN then
      cycle_detected = true
      cycle_params["__overflow__"] = true
      return text
    end
    -- Recursively replace %name with cycle detection
    s = s:gsub("%%([%a_][%w_]*)", function(n)
      local name = n
      local val = current_vars[name]
      if not val then
        return "%" .. n
      end
      if chain[name] then
        cycle_detected = true
        for k, _ in pairs(chain) do cycle_params[k] = true end
        cycle_params[name] = true
        return "%" .. n
      end
      chain[name] = true
      local expanded = substitute_vars(val, depth + 1, chain)
      chain[name] = nil
      return expanded
    end)
    return s
  end

  local changed = 0
  for i, line in ipairs(lines) do
    if cycle_detected then break end
    local is_param_row = row_in_param[i]

    -- Update current_vars when we hit a parameter definition row
    if is_param_row then
      local assignments = parse_assignments_from_line(line)
      for _, a in ipairs(assignments) do
        local name = a.name
        local value = a.value
        -- Substitute vars in the RHS so stored value is already resolved
        value = substitute_vars(value)
        if cycle_detected then break end
        if apply_arith then
          local num = eval_fn(value)
          collect_eval_error(i, value)
          if num then
            value = num
          end
        end
        current_vars[name] = value
      end
    end

    -- Decide whether to replace this line
    local should_replace = not is_param_row or replace_defs
    local is_function_expr = function_expr_rows[i]
    local is_repeat_data = repeat_block_rows[i]
    local do_arith = apply_arith and not is_function_expr and not is_repeat_data

    if should_replace then
      local t = trim(strip_number_prefix(line))
      if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" then
        -- Fast skip for plain lines with no params when not doing arithmetic
        if not do_arith and not line:find("%%") and not line:find("%[") then
          -- nothing to do
        else
          local new_line = line
          -- Global [expr] and %name replacement
          -- For re -b: skip on parameter rows to preserve %name = format
          if mode ~= "all" or not is_param_row then
            -- Replace [expr]
            new_line = new_line:gsub("%[([^%[%]]-)%]", function(expr)
              local replaced = substitute_vars(expr)
              if do_arith then
                local num = eval_fn(replaced)
                collect_eval_error(i, replaced)
                if num then return num end
              end
              -- Partial simplification: always try, even inside ~repeat blocks
              -- (loop variables like r1, r2 are preserved as unknown identifiers)
              local simplified = partial_eval_expr(replaced)
              if simplified then
                return simplified
              end
              return replaced
            end)
            if cycle_detected then break end
            -- Replace %name
            new_line = new_line:gsub("%%([%a_][%w_]*)", function(n)
              local val = current_vars[n]
              if val then return val end
              return "%" .. n
            end)
          end
          -- For re -b on definition rows: evaluate RHS of each assignment
          if is_param_row and replace_defs and do_arith then
            local assignments = parse_assignments_from_line(new_line)
            -- Process from right to left to avoid position shifts after replacement
            for idx = #assignments, 1, -1 do
              local a = assignments[idx]
              local lhs_pattern = a.name .. "%s*=%s*"
              local s, e = new_line:find(lhs_pattern)
              if s then
                local next_s = new_line:find("[%a_][%w_]*%s*=%s*", e + 1)
                local val_end = next_s and (next_s - 1) or #new_line
                local raw_val = new_line:sub(e + 1, val_end)
                -- Find effective end of value (before trailing comma, comment, or "description")
                local effective_end = #raw_val
                local comma_pos = raw_val:find(",%s*$")
                if comma_pos then
                  effective_end = comma_pos - 1
                else
                  local desc_pos = raw_val:find(',%s*".*"$')
                  if desc_pos then
                    effective_end = desc_pos - 1
                  end
                end
                local comment_pos = raw_val:find("%s[#$]")
                if comment_pos and comment_pos > 1 then
                  effective_end = math.min(effective_end, comment_pos - 1)
                end
                local tail = new_line:sub(e + effective_end + 1, val_end) .. new_line:sub(val_end + 1)
                local full_val = trim(raw_val:sub(1, effective_end))
                if full_val ~= "" then
                  full_val = substitute_vars(full_val)
                  local num = eval_fn(full_val)
                  collect_eval_error(i, full_val)
                  if num then
                    new_line = new_line:sub(1, e) .. num .. tail
                  end
                end
              end
            end
          end
          -- Simplify numeric expressions
          if do_arith and new_line ~= line and (mode ~= "all" or not is_param_row) then
            new_line = simplify_numeric_text_fixed_point(new_line, 4)
            collect_eval_error(i, new_line)
          end
          if new_line ~= line then
            entries[#entries + 1] = {
              row = i,
              before = line,
              after = new_line,
            }
            lines[i] = new_line
            changed = changed + 1
          end
        end
      end
    end
  end

  -- Second pass for apply_arith: resolve nested numeric expressions
  if not cycle_detected and apply_arith then
    for i, line in ipairs(lines) do
      if repeat_block_rows[i] or row_in_param[i] or row_in_include[i] then
        -- skip ~repeat block rows, parameter rows, and *INCLUDE rows
      else
        local t = trim(strip_number_prefix(line))
        if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" then
          local new_line = simplify_numeric_text_fixed_point(line, 4)
          -- Skip error collection for *FUNCTION expression rows:
          -- unknown variables (x, y, z, t) and crv()/fcn() calls are expected.
          if not function_expr_rows[i] then
            collect_eval_error(i, line)
          else
            -- Discard expected errors so they don't leak to subsequent rows
            current_eval_error = nil
          end
          if new_line ~= line then
            entries[#entries + 1] = {
              row = i,
              before = line,
              after = new_line,
            }
            lines[i] = new_line
            changed = changed + 1
          end
        end
      end
    end
  end

  if cycle_detected then
    local names = {}
    for k, _ in pairs(cycle_params) do
      if not k:match("^__") then
        names[#names + 1] = "%" .. k
      end
    end
    table.sort(names)
    local reason
    if #names > 0 then
      reason = "Circular parameter reference detected: " .. table.concat(names, ", ") .. ". Replace aborted."
    else
      reason = "Parameter substitution overflow (too deep or too large). Replace aborted."
    end
    vim.notify(reason, vim.log.levels.ERROR)
    if mode == "ref" then
      return -1, {}
    end
    return 0, {}
  end

  if #math_errors > 0 then
    local msgs = {}
    for idx, e in ipairs(math_errors) do
      if idx > 10 then
        msgs[#msgs + 1] = string.format("... and %d more error(s)", #math_errors - 10)
        break
      end
      msgs[#msgs + 1] = string.format("L%d: %s (%s)", e.row, e.reason, e.expr)
    end
    vim.notify("Math evaluation errors:\n" .. table.concat(msgs, "\n"), vim.log.levels.ERROR)
  end

  -- Expand ~repeat blocks for re -c
  if expand_repeat then
    local before_count = #lines
    local before_lines = {}
    for _, l in ipairs(lines) do
      table.insert(before_lines, l)
    end
    lines = expand_all_repeats(lines)
    local has_repeat_changes = (#lines ~= before_count)
    if not has_repeat_changes then
      for i = 1, #lines do
        if lines[i] ~= before_lines[i] then
          has_repeat_changes = true
          break
        end
      end
    end
    if has_repeat_changes then
      changed = changed + 1
      entries[#entries + 1] = {
        row = 1,
        before = "(~repeat blocks)",
        after = string.format("expanded to %d lines", #lines),
      }
    end
  end

  if changed > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end

  -- After re -b, align *PARAMETER and *PARAMETER_DEFAULT definitions
  if mode == "all" then
    align_parameter_blocks_in_buffer()
  end

  if changed > 0 then
    refresh_buffer_analysis(buf)
  end

  return changed, entries
end

local function show_cheatsheet_popup()
  local leader = tostring(vim.g.mapleader or "\\")
  local localleader = tostring(vim.g.maplocalleader or leader)
  local function k(lhs)
    local out = lhs
    out = out:gsub("<leader>", leader)
    out = out:gsub("<localleader>", localleader)
    return out
  end

  local lines = {}
  local line_meta = {}

  local function push_text(text, kind)
    lines[#lines + 1] = text
    line_meta[#line_meta + 1] = { kind = kind or "text" }
  end

  local sections = {
    {
      title = "[Core Editing]",
      items = {
        { k("<localleader>h"), "Toggle right help pane (keyword docs)" },
        { k("<localleader>c"), "Toggle comment/uncomment current keyword block" },
        { "dk", "Cut current block (keyword/control) into register" },
        { k("<localleader>y"), "Yank current block (keyword/control) into register" },
        { "p / P", "Put last cut block with native Vim paste" },
        { "<Tab>", "Jump to next parameter field" },
        { k("<localleader>I"), "Insert keyword template" },
        { k("<localleader>Q"), "Close popup / quickfix" },
        { "gh", "Show intrinsic hover docs" },
        { "<C-Space>", "Trigger Impetus completion" },
      },
    },
    {
      title = "[Navigation]",
      items = {
        { k("<localleader>n"), "Next keyword" },
        { k("<localleader>N"), "Previous keyword" },
        { k("<localleader>f"), "Toggle fold all keyword blocks" },
        { k("<localleader>t"), "Toggle current keyword block fold" },
        { k("<localleader>F"), "Toggle fold all control blocks (~if/~repeat/~convert/~scope)" },
        { k("<localleader>T"), "Toggle current control block fold" },
        { k("<localleader>z"), "Toggle fold all keyword + control blocks" },
        { k("<localleader>m"), "Jump to matching control block (and show [pairX])" },
        { "%", "Match jump (directive / brackets)" },
        { k("<localleader>b"), "Check missing/extra control block ends" },
        { k("<localleader>u"), "Open this quick help popup" },
        { k("<localleader>o"), "Open include file in left split" },
        { k("<localleader>O"), "Open in Impetus GUI" },
        { "K", "Docs under cursor" },
      },
    },
    {
      title = "[References]",
      items = {
        { "gr", "Find references of parameter under cursor" },
        { "gd", "Jump to parameter definition" },
        { k("<localleader><localleader>"), "Popup completion for ref/options" },
      },
    },
    {
      title = "[Main Commands]",
      items = {
        { ":info", "Open model/file/keyword info tree" },
        { ":Cgraph", "Open object/reference graph summary" },
        { ":Cgr", "Show inbound/outbound refs for object under cursor" },
        { ":Cgdel", "Check whether current object can be deleted safely" },
        { ":Cc", "Run lint checks on current buffer (Error/Warning/Suspicion)" },
        { ":Cc -a", "Run lint on all open buffers" },
        { ":clean", "Clear pairX markers and lint diagnostics" },
        { ":clean -c", "Warm clean: remove comments/blank/noise rows (smart keep)" },
        { ":clean -a", "Full clean: pairX + warm clean + prune + align PARAMETER defs" },
        { ":clean -s", "Simple beautify: align columns & normalize spacing (no delete)" },
        { ":re", "Replace custom params with values (basic ordered replace)" },
        { ":re -a", "Replace + evaluate numeric expressions" },
        { ":re -b", "Replace all (defs+refs) + eval with intrinsic functions" },
        { ":re -c", "Expand ~repeat blocks into concrete rows (re -a + unroll)" },
        { ":Cblock", "Check unmatched control block pairs" },
        { ":Update", "Force refresh index, lint, and ref marks" },
        { ":gui", "Open in Impetus GUI" },
        { ":obj", "Open object registry (parts, materials, functions, geometry, commands)" },
      },
    },
  }

  -- Compute global command width for aligned table columns
  local global_width = 0
  for _, section in ipairs(sections) do
    for _, item in ipairs(section.items) do
      global_width = math.max(global_width, vim.fn.strdisplaywidth(item[1]))
    end
  end
  global_width = global_width + 3  -- padding between columns

  local function push_item(cmd, desc)
    local cmd_display_width = vim.fn.strdisplaywidth(cmd)
    local pad = global_width - cmd_display_width
    lines[#lines + 1] = cmd .. string.rep(" ", pad) .. desc
    line_meta[#line_meta + 1] = { kind = "item", cmd = cmd, desc = desc, width = global_width }
  end

  push_text("IMPETUS NVIM QUICK HELP", "title")
  push_text(string.rep("═", global_width + 50), "divider")
  push_text("", "blank")

  for _, section in ipairs(sections) do
    push_text(section.title, "section")
    push_text(string.rep("─", global_width + 50), "divider")
    for _, item in ipairs(section.items) do
      push_item(item[1], item[2])
    end
    push_text("", "blank")
  end

  push_text("Press q / <Esc> / <CR> to close", "text")

  local function apply_cheatsheet_highlights(buf)
    for i, line in ipairs(lines) do
      local row = i - 1
      local meta = line_meta[i] or { kind = "text" }
      if meta.kind == "title" then
        vim.api.nvim_buf_add_highlight(buf, -1, "impetusCheatTitle", row, 0, -1)
      elseif meta.kind == "divider" then
        vim.api.nvim_buf_add_highlight(buf, -1, "impetusDivider", row, 0, -1)
      elseif meta.kind == "section" then
        vim.api.nvim_buf_add_highlight(buf, -1, "impetusCheatSection", row, 0, -1)
      elseif meta.kind == "item" then
        local cmd_display_width = vim.fn.strdisplaywidth(meta.cmd)
        local desc_col = global_width
        vim.api.nvim_buf_add_highlight(buf, -1, "impetusCheatCommand", row, 0, cmd_display_width)
        vim.api.nvim_buf_add_highlight(buf, -1, "impetusCheatDesc", row, desc_col, -1)
      elseif line ~= "" then
        vim.api.nvim_buf_add_highlight(buf, -1, "impetusCheatDesc", row, 0, -1)
      end
    end
  end

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width + 2, 64), math.floor(vim.o.columns * 0.85))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.85))
  local row = math.floor((vim.o.lines - height) / 2) - 1
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  apply_cheatsheet_highlights(buf)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = "markdown"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = math.max(0, row),
    col = math.max(0, col),
  })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false

  local function close_popup()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.keymap.set("n", "q", close_popup, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close_popup, { buffer = buf, silent = true })
  vim.keymap.set("n", "<CR>", close_popup, { buffer = buf, silent = true })
end

function M.reload_help(quiet)
  local path = best_help_path()
  if not path or path == "" then
    if not quiet then
      vim.notify("No source path in memory. Use :ImpetusLoadHelp first.", vim.log.levels.ERROR)
    end
    return false
  end
  local ok, err = store.load_from_file(path)
  if not ok then
    if not quiet then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return false
  end
  store.save_cache()
  if not quiet then
    vim.notify("Impetus database reloaded.", vim.log.levels.INFO)
  end
  return true
end

function M.dev_refresh(opts)
  opts = opts or {}
  local quiet = opts.quiet == true
  if opts.reload_plugin then
    pcall(vim.cmd, "silent! Lazy reload impetus.nvim")
  end
  if opts.reload_help ~= false then
    M.reload_help(quiet)
  end
end

function M.register()
  vim.api.nvim_create_user_command("ImpetusLoadHelp", function(opts)
    local path = opts.args
    if path == "" then
      vim.notify("Usage: :ImpetusLoadHelp /path/to/commands.help", vim.log.levels.ERROR)
      return
    end
    local ok, err = store.load_from_file(path)
    if not ok then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    local cache_path = store.save_cache()
    vim.notify("Impetus loaded from " .. store.get_path() .. "\ncache: " .. cache_path, vim.log.levels.INFO)
  end, { nargs = 1, complete = "file" })

  vim.api.nvim_create_user_command("ImpetusReload", function()
    M.reload_help(false)
  end, {})

  vim.api.nvim_create_user_command("ImpetusExportJson", function(opts)
    local target = opts.args
    if target == "" then
      vim.notify("Usage: :ImpetusExportJson /path/to/keywords.json", vim.log.levels.ERROR)
      return
    end
    local written = store.save_cache(target)
    vim.notify("Impetus keyword database exported to " .. written, vim.log.levels.INFO)
  end, { nargs = 1, complete = "file" })

  vim.api.nvim_create_user_command("ImpetusExportSnippets", function(opts)
    local target = opts.args
    if target == "" then
      vim.notify("Usage: :ImpetusExportSnippets /path/to/impetus.code-snippets", vim.log.levels.ERROR)
      return
    end
    snippets.export_vscode_json(target)
    vim.notify("Impetus snippets exported to " .. target, vim.log.levels.INFO)
  end, { nargs = 1, complete = "file" })

  vim.api.nvim_create_user_command("ImpetusLint", function()
    local diagnostics = lint.run(0)
    local counts = { error = 0, warning = 0, suspicion = 0 }
    for _, d in ipairs(diagnostics) do
      if d.severity == vim.diagnostic.severity.ERROR then
        counts.error = counts.error + 1
      elseif d.severity == vim.diagnostic.severity.WARN then
        counts.warning = counts.warning + 1
      elseif d.severity == vim.diagnostic.severity.HINT then
        counts.suspicion = counts.suspicion + 1
      end
    end
    local msg = string.format(
      "Impetus lint finished.  error=%d  warning=%d  suspicion=%d  (total=%d)",
      counts.error, counts.warning, counts.suspicion, #diagnostics
    )
    if counts.error > 0 then
      vim.notify(msg, vim.log.levels.WARN)
    elseif counts.warning > 0 then
      vim.notify(msg, vim.log.levels.WARN)
    else
      vim.notify(msg, vim.log.levels.INFO)
    end
  end, {})

  vim.api.nvim_create_user_command("ImpetusHelpOpen", function()
    side_help.open_for_current()
  end, {})

  vim.api.nvim_create_user_command("ImpetusHelpClose", function()
    side_help.close_for_current()
  end, {})

  vim.api.nvim_create_user_command("ImpetusHelpToggle", function()
    actions.toggle_help()
  end, {})

  vim.api.nvim_create_user_command("ImpetusCheatSheet", function()
    show_cheatsheet_popup()
  end, {})

  vim.api.nvim_create_user_command("ImpetusRefresh", function()
    M.dev_refresh({ reload_plugin = true, reload_help = true, quiet = false })
  end, {})

  vim.api.nvim_create_user_command("ImpetusUpdate", function()
    refresh_buffer_analysis(vim.api.nvim_get_current_buf())
    vim.notify("Impetus analysis updated.", vim.log.levels.INFO)
  end, {})

  local function run_clean_command(opts)
    local args = trim(opts.args or "")
    actions.clear_directive_pair_marks()
    -- Clear lint diagnostics produced by :Ccheck
    local lint_ns = vim.api.nvim_create_namespace("impetus-lint")
    local buf = vim.api.nvim_get_current_buf()
    vim.diagnostic.reset(lint_ns, buf)
    if args == "" then
      vim.notify("Impetus clean done. Pair markers and diagnostics cleared.", vim.log.levels.INFO)
      return
    end
    if args == "-c" then
      local removed, entries = clean_current_buffer()
      local log_lines = {
        string.format("[summary] removed=%d", removed),
      }
      if #entries > 0 then
        log_lines[#log_lines + 1] = "[warm clean]"
        for _, e in ipairs(entries) do
          log_lines[#log_lines + 1] = string.format("  L%-5d %-12s %s", e.row, e.reason, trim(e.line))
        end
      end
      local log_path = append_operation_log("clean -c", log_lines)
      vim.notify("Impetus clean -c done. Pair markers cleared, removed lines: " .. tostring(removed) .. " | log: " .. vim.fn.fnamemodify(log_path, ":~:."), vim.log.levels.INFO)
      return
    end
    if args == "-a" then
      local warm_removed, warm_entries = clean_current_buffer()
      local advanced_removed, adv_entries = advanced_clear_current_buffer()
      local aligned, aligned_entries = align_parameter_blocks_in_buffer()

      local log_lines = {
        string.format(
          "[summary] removed=%d (warm=%d adv=%d)  aligned=%d",
          warm_removed + advanced_removed, warm_removed, advanced_removed, aligned
        ),
      }
      if #warm_entries > 0 then
        log_lines[#log_lines + 1] = "[warm clean]"
        for _, e in ipairs(warm_entries) do
          log_lines[#log_lines + 1] = string.format("  L%-5d %-12s %s", e.row, e.reason, trim(e.line))
        end
        log_lines[#log_lines + 1] = ""
      end
      if #adv_entries > 0 then
        log_lines[#log_lines + 1] = "[advanced clean]"
        for _, e in ipairs(adv_entries) do
          if e.reason == "unknown-block" then
            log_lines[#log_lines + 1] = string.format("  L%-5d unknown-block    %s (%d lines)", e.row, e.keyword, e.count or 1)
          else
            log_lines[#log_lines + 1] = string.format("  L%-5d %-16s %s  (%s)", e.row, e.reason, trim(e.line), e.keyword or "")
          end
        end
        log_lines[#log_lines + 1] = ""
      end
      if #aligned_entries > 0 then
        log_lines[#log_lines + 1] = "[aligned]"
        for _, e in ipairs(aligned_entries) do
          log_lines[#log_lines + 1] = string.format("  L%-5d %-16s %s  ->  %s", e.row, e.keyword, trim(e.old_line), trim(e.new_line))
        end
        log_lines[#log_lines + 1] = ""
      end
      local log_path = append_operation_log("clean -a", log_lines)

      -- Re-apply intrinsic highlights since buffer content was rewritten
      vim.b.impetus_intrinsic_applied = 0
      intrinsic.apply_syntax_for_current_buffer()

      vim.notify(
        string.format(
          "Impetus clean -a done. Removed: %d (warm=%d adv=%d), aligned: %d | log: %s",
          warm_removed + advanced_removed, warm_removed, advanced_removed, aligned,
          vim.fn.fnamemodify(log_path, ":~:.")
        ),
        vim.log.levels.INFO
      )
      return
    end
    if args == "-s" then
      local changed, entries = simple_beautify_buffer()
      local log_lines = { string.format("[summary] changed=%d", changed) }
      if #entries > 0 then
        log_lines[#log_lines + 1] = "[beautified]"
        for _, e in ipairs(entries) do
          log_lines[#log_lines + 1] = string.format("  L%-5d %-16s  %s  ->  %s", e.row, e.keyword, trim(e.old_line), trim(e.new_line))
        end
      end
      local log_path = append_operation_log("clean -s", log_lines)
      vim.notify(string.format("Impetus clean -s done. Beautified: %d | log: %s", changed, vim.fn.fnamemodify(log_path, ":~:.")), vim.log.levels.INFO)
      return
    end
    vim.notify("Usage: :clean | :clean -c | :clean -a | :clean -s", vim.log.levels.WARN)
  end

  vim.api.nvim_create_user_command("ImpetusClean", run_clean_command, { nargs = "*" })
  vim.api.nvim_create_user_command("ImpetusClear", run_clean_command, { nargs = "*" })

  local function parse_re_args(args_str)
    local args = trim(args_str or "")
    if args:find("%f[%S]%-c%f[%s]") ~= nil or args == "-c" then
      return "repeat", "re -c"
    elseif args:find("%f[%S]%-b%f[%s]") ~= nil or args == "-b" then
      return "all", "re -b"
    elseif args:find("%f[%S]%-a%f[%s]") ~= nil or args == "-a" then
      return "arith", "re -a"
    else
      return "ref", "re"
    end
  end

  vim.api.nvim_create_user_command("ImpetusReplaceParams", function(opts)
    local mode, mode_str = parse_re_args(opts.args)
    local changed, entries = replace_params_in_buffer(mode)
    if changed == -1 then
      -- Cycle/overflow detected in ref mode: nothing was changed, skip logging
      return
    end
    local log_lines = {
      string.format("[summary] changed=%d mode=%s", changed, mode_str),
    }
    for _, e in ipairs(entries or {}) do
      log_lines[#log_lines + 1] = string.format("  L%-5d before: %s", e.row, trim(e.before))
      log_lines[#log_lines + 1] = string.format("         after : %s", trim(e.after))
    end
    local log_path = append_operation_log(mode_str, log_lines)
    vim.notify("Impetus replace done. Updated lines: " .. tostring(changed) .. " | log: " .. vim.fn.fnamemodify(log_path, ":~:."), vim.log.levels.INFO)
  end, { nargs = "*" })

  vim.api.nvim_create_user_command("ImpetusOutline", function()
    local idx = analysis.build_buffer_index(0)
    local qf = {}
    for _, k in ipairs(idx.keywords or {}) do
      qf[#qf + 1] = {
        bufnr = 0,
        lnum = k.row,
        col = 1,
        text = k.keyword,
      }
    end
    vim.fn.setqflist({}, " ", { title = "Impetus Outline", items = qf })
    vim.cmd("copen")
  end, {})

  local function show_object_refs(obj, cur_row)
    local bufnr = vim.api.nvim_get_current_buf()
    local cur_file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
    local def = analysis.object_definition(bufnr, obj.obj_type, obj.id)
    local refs_list = analysis.object_references(bufnr, obj.obj_type, obj.id)
    local obj_items = {}
    local seen = {}
    if def then
      local def_file = def.file or cur_file
      if not (def_file == cur_file and def.row == cur_row) then
        local key = string.format("%s:%d:%d", def_file, def.row or 0, def.col or 0)
        seen[key] = true
        obj_items[#obj_items + 1] = { kind = "def", row = def.row, col = def.col or 0, line = def.line or "", file = def_file, keyword = def.keyword }
      end
    end
    for _, r in ipairs(refs_list) do
      local ref_file = r.file or cur_file
      if not (ref_file == cur_file and r.row == cur_row) then
        local key = string.format("%s:%d:%d", ref_file, r.row or 0, r.col or 0)
        if not seen[key] then
          seen[key] = true
          obj_items[#obj_items + 1] = { kind = "ref", row = r.row, col = r.col or 0, line = r.line or "", file = ref_file, keyword = r.keyword }
        end
      end
    end
    if #obj_items == 0 then
      vim.notify(string.format("No refs for %s ID %s", obj.obj_type, obj.id), vim.log.levels.INFO)
    elseif #obj_items == 1 then
      jump_to_item(obj_items[1])
    else
      show_param_refs_popup(obj_items, string.format("%s:%s", obj.obj_type, obj.id))
    end
  end

  vim.api.nvim_create_user_command("ImpetusParamRefs", function(opts)
    local name = opts.args
    if name == "" then
      -- Check if cursor is on fcn(id) / crv(id) and the param supports it
      local obj_type, obj_id = cursor_fcn_crv_id()
      if obj_type and obj_id then
        show_object_refs({ obj_type = obj_type, id = obj_id }, vim.api.nvim_win_get_cursor(0)[1])
        return
      end
      name = param_under_cursor() or ""
    end
    if name == "" then
      -- No %param under cursor: try object ID (reference field or definition keyword)
      local bufnr = vim.api.nvim_get_current_buf()
      local obj = analysis.object_under_cursor(bufnr) or analysis.object_def_under_cursor(bufnr)
      if obj then
        show_object_refs(obj, vim.api.nvim_win_get_cursor(0)[1])
        return
      end
      vim.notify("Usage: :ImpetusParamRefs <param_name>", vim.log.levels.WARN)
      return
    end
    local refs = dedupe_param_refs(analysis.param_references_all(vim.api.nvim_get_current_buf(), name))
    local cur = vim.api.nvim_win_get_cursor(0)
    local cur_row = cur[1]
    local cur_file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
    local items = {}
    local def_keys = {}
    for _, d in ipairs(refs.defs or {}) do
      if not ((d.row or 0) == cur_row and (d.file or "") == cur_file) then
        items[#items + 1] = { kind = "def", row = d.row, col = d.col, line = d.line or "", file = d.file or "" }
        def_keys[(d.file or "") .. ":" .. tostring(d.row or 0)] = true
      end
    end
    for _, r in ipairs(refs.refs or {}) do
      local key = (r.file or "") .. ":" .. tostring(r.row or 0)
      if not ((r.row or 0) == cur_row and (r.file or "") == cur_file) and not def_keys[key] then
        items[#items + 1] = { kind = "ref", row = r.row, col = r.col, line = r.line or "", file = r.file or "" }
      end
    end
    table.sort(items, function(a, b)
      local a_def = a.kind == "def"
      local b_def = b.kind == "def"
      if a_def ~= b_def then
        return a_def
      end
      if (a.file or "") ~= (b.file or "") then
        return (a.file or "") < (b.file or "")
      end
      if (a.row or 0) ~= (b.row or 0) then
        return (a.row or 0) < (b.row or 0)
      end
      return (a.col or 0) < (b.col or 0)
    end)

    if #items == 0 then
      local bufnr = vim.api.nvim_get_current_buf()
      local obj = analysis.object_under_cursor(bufnr) or analysis.object_def_under_cursor(bufnr)
      if obj then
        show_object_refs(obj, vim.api.nvim_win_get_cursor(0)[1])
        return
      end
      vim.notify("No refs for %" .. normalize_param_name(name), vim.log.levels.INFO)
      return
    end
    if #items == 1 then
      jump_to_item(items[1])
      return
    end
    show_param_refs_popup(items, name)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("ImpetusParamDef", function(opts)
    local name = opts.args
    if name == "" then
      -- Check if cursor is on fcn(id) / crv(id) and the param supports it
      local obj_type, obj_id, prefix = cursor_fcn_crv_id()
      if obj_type and obj_id then
        local def = analysis.object_definition(vim.api.nvim_get_current_buf(), obj_type, obj_id)
        if def then
          jump_to_item(def)
          return
        end
        vim.notify("No definition found for " .. prefix .. "(" .. obj_id .. ")", vim.log.levels.INFO)
        return
      end
      name = param_under_cursor() or ""
    end
    if name ~= "" then
      local refs = dedupe_param_refs(analysis.param_references_all(vim.api.nvim_get_current_buf(), name))
      if refs.defs and #refs.defs > 0 then
        jump_to_item(refs.defs[1])
        return
      end
      vim.notify("No definition found for %" .. normalize_param_name(name), vim.log.levels.INFO)
      return
    end
    -- Check if cursor is ON a definition keyword (already at definition)
    local def_obj = analysis.object_def_under_cursor(vim.api.nvim_get_current_buf())
    if def_obj then
      vim.notify(string.format("Already at %s definition (ID %s)", def_obj.obj_type, def_obj.id), vim.log.levels.INFO)
      return
    end
    -- Fallback: object ID under cursor (reference field)
    local obj = analysis.object_under_cursor(vim.api.nvim_get_current_buf())
    if obj then
      local def = analysis.object_definition(vim.api.nvim_get_current_buf(), obj.obj_type, obj.id)
      if def then
        jump_to_item(def)
        return
      end
      vim.notify(string.format("No definition for %s ID %s", obj.obj_type, obj.id), vim.log.levels.INFO)
      return
    end
    vim.notify("Usage: :ImpetusParamDef <param_name>", vim.log.levels.WARN)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("ImpetusObjects", function()
    local idx = analysis.build_buffer_index(0)
    local qf = {}
    local order = { "part", "material", "function", "geometry", "command" }
    for _, t in ipairs(order) do
      local keys = {}
      for id, _ in pairs(idx.objects[t] or {}) do
        keys[#keys + 1] = id
      end
      table.sort(keys, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na and nb then return na < nb end
        return a < b
      end)
      for _, id in ipairs(keys) do
        qf[#qf + 1] = {
          bufnr = 0,
          lnum = 1,
          col = 1,
          text = string.format("[%s] %s", t, id),
        }
      end
    end
    vim.fn.setqflist({}, " ", { title = "Impetus Objects", items = qf })
    vim.cmd("copen")
  end, {})

  vim.api.nvim_create_user_command("ImpetusInfo", function()
    info.toggle_for_current()
  end, {})

  vim.api.nvim_create_user_command("ImpetusGraphInfo", function()
    require("impetus.graph").open_summary_for_current_buffer()
  end, {})

  vim.api.nvim_create_user_command("ImpetusGraphRefs", function(opts)
    require("impetus.graph").open_refs_for_current_buffer(opts.args)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("ImpetusGraphDeleteCheck", function(opts)
    require("impetus.graph").open_delete_check_for_current_buffer(opts.args)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("ImpetusRefComplete", function()
    actions.show_ref_completion()
  end, {})

  vim.api.nvim_create_user_command("ImpetusOpenGUI", function()
    actions.open_in_gui()
  end, {})

  vim.api.nvim_create_user_command("ImpetusHighlightProbe", function()
    arm_highlight_probe()
  end, {})

  vim.api.nvim_create_user_command("ImpetusCheckBlocks", function()
    actions.check_blocks()
  end, {})

  vim.api.nvim_create_user_command("ImpetusFoldBounds", function()
    actions.debug_fold_bounds()
  end, {})

  vim.api.nvim_create_user_command("ImpetusTryKeywordFold", function()
    actions.debug_try_keyword_fold()
  end, {})

  vim.api.nvim_create_user_command("ImpetusTryControlFold", function()
    actions.debug_try_control_fold()
  end, {})

  vim.api.nvim_create_user_command("ImpetusFoldDoctor", function()
    local lines = render_fold_doctor_lines()
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    vim.bo[buf].filetype = "lua"
    vim.api.nvim_buf_set_name(buf, "ImpetusFoldDoctor")
  end, {})

  if config.get().dev_mode then
    vim.api.nvim_create_user_command("ImpetusDebugWindows", function()
      local lines = render_debug_lines()
      vim.cmd("botright new")
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].swapfile = false
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      vim.bo[buf].readonly = true
      vim.bo[buf].filetype = "lua"
      vim.api.nvim_buf_set_name(buf, "ImpetusDebugWindows")
    end, {})

    vim.api.nvim_create_user_command("ImpetusDoctor", function()
      local lines = render_doctor_lines()
      vim.cmd("botright new")
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].swapfile = false
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      vim.bo[buf].readonly = true
      vim.bo[buf].filetype = "lua"
      vim.api.nvim_buf_set_name(buf, "ImpetusDoctor")
    end, {})
  end

  -- Short command family (GVim-style ergonomics)
  add_alias("Cc", "ImpetusLint")
  add_alias("Cgraph", "ImpetusGraphInfo")
  add_alias("Cgr", "ImpetusGraphRefs")
  add_alias("Cgdel", "ImpetusGraphDeleteCheck")
  add_alias("Chlprobe", "ImpetusHighlightProbe")
  add_alias("Cref", "ImpetusRefComplete")
  add_alias("Cf", "ImpetusRefComplete")
  add_alias("Cregistry", "ImpetusObjects")
  add_alias("Cr", "ImpetusObjects")
  add_alias("Obj", "ImpetusObjects")
  add_alias("Cblock", "ImpetusCheckBlocks")
  add_alias("Cfoldbounds", "ImpetusFoldBounds")
  add_alias("Ctrykwfold", "ImpetusTryKeywordFold")
  add_alias("Ctryctlfold", "ImpetusTryControlFold")
  add_alias("Cfolddbg", "ImpetusFoldDoctor")
  add_alias("Update", "ImpetusUpdate")

  vim.api.nvim_create_user_command("ImpetusRefMarksToggle", function()
    require("impetus.ref_marks").toggle()
  end, {})
  add_alias("Crm", "ImpetusRefMarksToggle")

  if config.get().dev_mode then
    add_alias("Cdbg", "ImpetusDebugWindows")
    add_alias("Cdoctor", "ImpetusDoctor")
  end

  -- Command-line short forms
  pcall(vim.keymap.del, "c", "<CR>")
  vim.keymap.set("c", "<kMinus>", "-")
  vim.keymap.set("c", "<S-kMinus>", "-")
  vim.keymap.set("c", "<CR>", function()
    if vim.fn.getcmdtype() == ":" then
      local line = normalize_minus_variants(vim.fn.getcmdline() or "")
      local cmd = vim.trim((line:match("^(%S+)") or ""))
      if cmd == "re" then
        local args = normalize_minus_variants(vim.trim(line:match("^%S+%s*(.*)$") or ""))
        local mode, mode_str = parse_re_args(args)
        vim.schedule(function()
          local changed, entries = replace_params_in_buffer(mode)
          local log_lines = {
            string.format("[summary] changed=%d mode=%s", changed, mode_str),
          }
          for _, e in ipairs(entries or {}) do
            log_lines[#log_lines + 1] = string.format("  L%-5d before: %s", e.row, trim(e.before))
            log_lines[#log_lines + 1] = string.format("         after : %s", trim(e.after))
          end
          local log_path = append_operation_log(mode_str, log_lines)
          vim.notify("Impetus replace done. Updated lines: " .. tostring(changed) .. " | log: " .. vim.fn.fnamemodify(log_path, ":~:."), vim.log.levels.INFO)
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "clean" then
        local args = normalize_minus_variants(vim.trim(line:match("^%S+%s*(.*)$") or ""))
        vim.schedule(function()
          run_clean_command({ args = args })
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "info" then
        vim.schedule(function()
          info.toggle_for_current()
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "help" then
        vim.schedule(function()
          show_cheatsheet_popup()
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "gui" then
        vim.schedule(function()
          actions.open_in_gui()
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "obj" then
        vim.schedule(function()
          vim.cmd("ImpetusObjects")
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      end
    end
    return vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  end, { expr = true, noremap = true })
end

return M
