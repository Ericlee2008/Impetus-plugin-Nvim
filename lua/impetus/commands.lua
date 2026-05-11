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
      local inner_search = 1
      while inner_search <= #inner do
        local ps, pe, pname = inner:find("%%([%a_][%w_]*)", inner_search)
        if not ps then
          break
        end
        local abs_s = s + ps
        local abs_e = s + pe
        if col >= abs_s and col <= abs_e then
          return pname
        end
        inner_search = pe + 1
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


-- Legacy helpers: kept for backward compatibility; use log.append() directly.
local function current_operation_log_path()
  return log.log_path(), vim.fn.expand("%:p")
end

local function append_operation_log(operation, details)
  return log.append(operation, details)
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
        { k("<localleader>H"), "Open full online manual for current keyword" },
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
        { ":re -b / :Re -b", "Replace all (defs+refs) + eval with intrinsic functions" },
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
    require("impetus.replace_engine").refresh_buffer_analysis(vim.api.nvim_get_current_buf())
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
      local removed, entries = require("impetus.clean_engine").clean_current_buffer()
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
      local clean_engine = require("impetus.clean_engine")
      local warm_removed, warm_entries = clean_engine.clean_current_buffer()
      local advanced_removed, adv_entries = clean_engine.advanced_clear_current_buffer()
      local aligned, aligned_entries = clean_engine.align_parameter_blocks_in_buffer()
      local beautified, beautified_entries = clean_engine.simple_beautify_buffer()

      local log_lines = {
        string.format(
          "[summary] removed=%d (warm=%d adv=%d)  aligned=%d  beautified=%d",
          warm_removed + advanced_removed, warm_removed, advanced_removed, aligned, beautified
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
      if #beautified_entries > 0 then
        log_lines[#log_lines + 1] = "[beautified]"
        for _, e in ipairs(beautified_entries) do
          log_lines[#log_lines + 1] = string.format("  L%-5d %-16s  %s  ->  %s", e.row, e.keyword, trim(e.old_line), trim(e.new_line))
        end
        log_lines[#log_lines + 1] = ""
      end
      local log_path = append_operation_log("clean -a", log_lines)

      -- Re-apply intrinsic highlights since buffer content was rewritten
      vim.b.impetus_intrinsic_applied = 0
      intrinsic.apply_syntax_for_current_buffer()

      vim.notify(
        string.format(
          "Impetus clean -a done. Removed: %d (warm=%d adv=%d), aligned: %d, beautified: %d | log: %s",
          warm_removed + advanced_removed, warm_removed, advanced_removed, aligned, beautified,
          vim.fn.fnamemodify(log_path, ":~:.")
        ),
        vim.log.levels.INFO
      )
      return
    end
    if args == "-s" then
      local changed, entries = require("impetus.clean_engine").simple_beautify_buffer()
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

  vim.api.nvim_create_user_command("ImpetusDebugRefs", function()
    M.show_buffer_refs()
  end, {})

  local function parse_re_args(args_str)
    local args = require("impetus.replace_engine").normalize_minus_variants(trim(args_str or ""))
    local compact = args:lower():gsub("%s+", "")
    if compact:find("-c", 1, true) ~= nil then
      return "repeat", "re -c"
    elseif compact:find("-b", 1, true) ~= nil then
      return "all", "re -b"
    elseif compact:find("-a", 1, true) ~= nil then
      return "arith", "re -a"
    else
      return "ref", "re"
    end
  end

  local function run_replace_command(opts)
    local mode, mode_str = parse_re_args(opts.args)
    local changed, entries = require("impetus.replace_engine").replace_params_in_buffer(mode)
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
    vim.notify("Impetus replace done (" .. mode_str .. "). Updated lines: " .. tostring(changed) .. " | log: " .. vim.fn.fnamemodify(log_path, ":~:."), vim.log.levels.INFO)
  end

  vim.api.nvim_create_user_command("ImpetusReplaceParams", run_replace_command, { nargs = "*" })
  vim.api.nvim_create_user_command("Re", run_replace_command, { nargs = "*" })

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

  vim.api.nvim_create_user_command("ImpetusPreviewGeometry", function()
    actions.preview_geometry()
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
  add_alias("Cgeo", "ImpetusPreviewGeometry")
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
  pcall(vim.cmd, "silent! cunabbrev re")
  vim.cmd([[cnoreabbrev <expr> re getcmdtype() ==# ':' && getcmdline() =~# '^\s*re\>' ? 'Re' : 're']])
  pcall(vim.keymap.del, "c", "<CR>")
  vim.keymap.set("c", "<kMinus>", "-")
  vim.keymap.set("c", "<S-kMinus>", "-")
  vim.keymap.set("c", "<CR>", function()
    if vim.fn.getcmdtype() == ":" then
      local line = require("impetus.replace_engine").normalize_minus_variants(vim.fn.getcmdline() or "")
      local cmd = vim.trim((line:match("^(%S+)") or ""))
      if cmd == "re" then
        local args = require("impetus.replace_engine").normalize_minus_variants(vim.trim(line:match("^%S+%s*(.*)$") or ""))
        local mode, mode_str = parse_re_args(args)
        vim.schedule(function()
          local changed, entries = require("impetus.replace_engine").replace_params_in_buffer(mode)
          local log_lines = {
            string.format("[summary] changed=%d mode=%s", changed, mode_str),
          }
          for _, e in ipairs(entries or {}) do
            log_lines[#log_lines + 1] = string.format("  L%-5d before: %s", e.row, trim(e.before))
            log_lines[#log_lines + 1] = string.format("         after : %s", trim(e.after))
          end
          local log_path = append_operation_log(mode_str, log_lines)
          vim.notify("Impetus replace done (" .. mode_str .. "). Updated lines: " .. tostring(changed) .. " | log: " .. vim.fn.fnamemodify(log_path, ":~:."), vim.log.levels.INFO)
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "clean" then
        local args = require("impetus.replace_engine").normalize_minus_variants(vim.trim(line:match("^%S+%s*(.*)$") or ""))
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

-- Debug: show object references for current buffer and cross-file definitions
function M.show_buffer_refs()
  local bufnr = vim.api.nvim_get_current_buf()
  local idx = analysis.build_buffer_index(bufnr)
  local cross = analysis.build_cross_file_object_index(bufnr)

  local msg = "=== Object References in current buffer ===\n"
  local ref_count = 0
  for obj_type, refs in pairs(idx.object_refs or {}) do
    for idv, list in pairs(refs) do
      for i, info in ipairs(list) do
        ref_count = ref_count + 1
        local has_cross_def = (cross.defs[obj_type] or {})[idv] ~= nil
        local mark_status = has_cross_def and "✓" or "✗"
        msg = msg .. string.format("  [%d] %s[%s] @ row %d col %d  %s\n", ref_count, obj_type, idv, info.row, info.col, mark_status)
      end
    end
  end

  if ref_count == 0 then
    msg = "No object references found."
  else
    msg = msg .. string.format("\nTotal references found: %d\n", ref_count)
    msg = msg .. "\n=== Cross-file Element Definitions ===\n"
    local elem_defs = cross.defs["element"] or {}
    if next(elem_defs) then
      msg = msg .. "  " .. table.concat(vim.tbl_keys(elem_defs), ", ") .. "\n"
    else
      msg = msg .. "  (none)\n"
    end
  end

  print(msg)
  vim.notify(msg, vim.log.levels.INFO)
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

M.trim = trim
M.strip_number_prefix = strip_number_prefix
M.parse_keyword = parse_keyword
M.split_keyword_blocks = split_keyword_blocks
M.is_comment_line = is_comment_line
M.is_blank_line = is_blank_line
M.is_comma_only_line = is_comma_only_line
M.is_meta_row = is_meta_row
M.parse_include_path_from_line = parse_include_path_from_line

return M
