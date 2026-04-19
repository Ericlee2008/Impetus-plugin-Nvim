local store = require("impetus.store")
local snippets = require("impetus.snippets")
local lint = require("impetus.lint")
local side_help = require("impetus.side_help")
local config = require("impetus.config")
local analysis = require("impetus.analysis")
local actions = require("impetus.actions")
local info = require("impetus.info")

local M = {}

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_param_name(s)
  return ((s or ""):gsub("^%%", ""):gsub("^%[", ""):gsub("%]$", "")):lower()
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
  for i, it in ipairs(items or {}) do
    local file_tag = ""
    if has_cross_file then
      local fname = (it.file and it.file ~= "") and vim.fn.fnamemodify(it.file, ":t") or "?"
      file_tag = "[" .. fname .. "] "
    end
    lines[#lines + 1] = string.format("%2d [%s] %sL%-5d %s", i, it.kind or "ref", file_tag, it.row or 1, trim(it.line or ""))
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
      local low = l:lower()
      local p1 = low:find("%%" .. needle, 1, true)
      if p1 then
        vim.api.nvim_buf_add_highlight(buf, -1, "impetusParam", lnum, p1 - 1, p1 - 1 + #needle + 1)
      else
        local p2 = low:find(needle, 1, true)
        if p2 then
          vim.api.nvim_buf_add_highlight(buf, -1, "impetusParam", lnum, p2 - 1, p2 - 1 + #needle)
        end
      end
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
    local entry = store.get_keyword(b.keyword)
    local sig_rows = entry and entry.signature_rows or nil
    out[#out + 1] = lines[b.start_row] or ""
    local data_row_idx = 0

    for r = b.start_row + 1, b.end_row do
      local line = lines[r] or ""
      local drop = false
      local reason = nil

      if is_comment_line(line) or is_blank_line(line) then
        drop = true
        reason = is_comment_line(line) and "comment" or "blank"
      elseif is_comma_only_line(line) then
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
        entries[#entries + 1] = { row = r, line = line, reason = reason or "?" }
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
    if store.get_keyword(b.keyword) then
      local block_lines = {}
      local block_rows = {}
      for r = b.start_row, b.end_row do
        local line = lines[r] or ""
        if not is_comment_line(line) then
          block_lines[#block_lines + 1] = line
          block_rows[#block_rows + 1] = r
        else
          removed = removed + 1
          entries[#entries + 1] = { row = r, line = line, reason = "comment", keyword = b.keyword }
        end
      end

      while #block_lines > 0 and is_blank_line(block_lines[1] or "") do
        entries[#entries + 1] = { row = block_rows[1], line = block_lines[1], reason = "leading-blank", keyword = b.keyword }
        table.remove(block_lines, 1)
        table.remove(block_rows, 1)
        removed = removed + 1
      end
      while #block_lines > 0 and is_blank_line(block_lines[#block_lines] or "") do
        entries[#entries + 1] = { row = block_rows[#block_rows], line = block_lines[#block_lines], reason = "trailing-blank", keyword = b.keyword }
        table.remove(block_lines, #block_lines)
        table.remove(block_rows, #block_rows)
        removed = removed + 1
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

local function format_parameter_definition_lines(block_lines)
  local specs = {}
  local max_lhs = 0
  local max_rhs = 0

  for i, line in ipairs(block_lines or {}) do
    local indent, lhs, rhs, comment = line:match("^(%s*)(%%?[%a_][%w_]*)%s*=%s*(.-)%s*(,.*)$")
    if not lhs then
      indent, lhs, rhs = line:match("^(%s*)(%%?[%a_][%w_]*)%s*=%s*(.-)%s*$")
    end
    if lhs and rhs and rhs ~= "" then
      rhs = trim(rhs)
      comment = comment and trim(comment) or nil
      specs[i] = {
        indent = indent or "",
        lhs = lhs,
        rhs = rhs,
        comment = comment,
      }
      max_lhs = math.max(max_lhs, #lhs)
      max_rhs = math.max(max_rhs, #rhs)
    end
  end

  if max_lhs == 0 then
    return block_lines
  end

  local out = {}
  for i, line in ipairs(block_lines or {}) do
    local spec = specs[i]
    if not spec then
      out[#out + 1] = line
    else
      local lhs_pad = string.rep(" ", math.max(1, max_lhs - #spec.lhs + 1))
      local text = spec.indent .. spec.lhs .. lhs_pad .. "= " .. spec.rhs
      if spec.comment then
        local rhs_pad = string.rep(" ", math.max(1, max_rhs - #spec.rhs + 1))
        text = text .. rhs_pad .. spec.comment
      end
      out[#out + 1] = text
    end
  end
  return out
end

local function align_parameter_blocks_in_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = split_keyword_blocks(lines)
  if #blocks == 0 then
    return 0
  end

  local changed = 0
  for _, b in ipairs(blocks) do
    if b.keyword == "*PARAMETER" or b.keyword == "*PARAMETER_DEFAULT" then
      local block_lines = {}
      for r = b.start_row + 1, b.end_row do
        block_lines[#block_lines + 1] = lines[r] or ""
      end
      local formatted = format_parameter_definition_lines(block_lines)
      for idx, new_line in ipairs(formatted) do
        local row = b.start_row + idx
        if lines[row] ~= new_line then
          lines[row] = new_line
          changed = changed + 1
        end
      end
    end
  end

  if changed > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  return changed
end

local function current_operation_log_path()
  local buf_name = vim.fn.expand("%:p")
  local log_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
  return log_dir .. "/impetus_nvim.log", buf_name
end

local function append_operation_log(operation, details)
  local log_path, buf_name = current_operation_log_path()
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

local function parse_assignments_from_line(line)
  local t = strip_number_prefix(line or "")
  t = trim((t:gsub("%s[#$].*$", "")))
  if t == "" then
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
    value = trim((value:match("^([^,]+)") or value))
    if value ~= "" then
      out[#out + 1] = { name = it.name:lower(), value = value }
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

local function try_eval_numeric(expr)
  local src = trim(expr or "")
  if src == "" then
    return nil
  end
  if src:find("[^%d%+%-%*%/%^%(%)%.eE%s]") then
    return nil
  end
  local f = load("return (" .. src .. ")", "impetus_eval", "t", {})
  if not f then
    return nil
  end
  local ok, v = pcall(f)
  if ok and type(v) == "number" then
    local abs_v = math.abs(v)
    local prefer_sci = src:find("[eE]") ~= nil
      or (abs_v ~= 0 and (abs_v >= 1e6 or abs_v < 1e-4))
    if prefer_sci then
      local s = string.format("%.8e", v)
      local mant, exp = s:match("^(.-)e([%+%-]%d+)$")
      if mant and exp then
        mant = mant:gsub("(%..-)0+$", "%1")
        mant = mant:gsub("%.$", "")
        exp = exp:gsub("%+","")
        exp = exp:gsub("^(-?)0+(%d)", "%1%2")
        if exp == "" then
          exp = "0"
        end
        return mant .. "e" .. exp
      end
      return s
    end
    return string.format("%.15g", v)
  end
  return nil
end

local function is_plain_numeric_literal(expr)
  local src = trim(expr or "")
  if src == "" then
    return false
  end
  return src:match("^[-+]?%d+%.?%d*([eE][-+]?%d+)?$") ~= nil
    or src:match("^[-+]?%d*%.%d+([eE][-+]?%d+)?$") ~= nil
end

local function simplify_numeric_text(text)
  local s = text or ""

  s = s:gsub("%[([^%[%]]-)%]", function(expr)
    local num = try_eval_numeric(expr)
    if num then
      return num
    end
    return "[" .. expr .. "]"
  end)

  s = s:gsub("([^,]+)", function(field)
    local ft = trim(field)
    if ft ~= "" and not is_plain_numeric_literal(ft) then
      local num = try_eval_numeric(ft)
      if num then
        local lead = field:match("^(%s*)")
        local trail = field:match("(%s*)$")
        return lead .. num .. trail
      end
    end
    return field
  end)

  local whole = trim(s)
  if whole ~= "" and whole:find(",", 1, true) == nil then
    local num = try_eval_numeric(whole)
    if num then
      local lead = s:match("^(%s*)")
      local trail = s:match("(%s*)$")
      return lead .. num .. trail
    end
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

local function replace_params_in_buffer(apply_arith)
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local vars, blocks = build_param_tables(lines, vim.api.nvim_buf_get_name(buf))
  if vim.tbl_count(vars) == 0 then
    return 0, {}
  end
  local entries = {}

  local row_in_param = {}
  for _, b in ipairs(blocks) do
    local ku = (b.keyword or ""):upper()
    if ku == "*PARAMETER" or ku == "*PARAMETER_DEFAULT" then
      for r = b.start_row, b.end_row do
        row_in_param[r] = true
      end
    end
  end

  local memo_expr_plain, memo_expr_numeric, memo_num, visiting = {}, {}, {}, {}
  local function resolve_expr(name, numeric)
    name = (name or ""):lower()
    local memo_expr = numeric and memo_expr_numeric or memo_expr_plain
    if memo_expr[name] then
      return memo_expr[name]
    end
    if visiting[name] then
      return vars[name]
    end
    visiting[name] = true
    local raw = vars[name]
    if not raw then
      visiting[name] = nil
      return nil
    end
    local raw_trim = trim(raw)
    local v = raw
    v = v:gsub("%[%s*%%([%a_][%w_]*)%s*%]", function(n)
      return resolve_expr(n) or ("%[" .. "%" .. n .. "]")
    end)
    v = v:gsub("%%([%a_][%w_]*)", function(n)
      return resolve_expr(n) or ("%" .. n)
    end)
    if numeric then
      local num = try_eval_numeric(v)
      if num then
        local resolved_trim = trim(v)
        if is_plain_numeric_literal(raw_trim) then
          v = raw_trim
        elseif is_plain_numeric_literal(resolved_trim) then
          v = resolved_trim
        else
          v = num
        end
      end
    end
    memo_expr[name] = v
    visiting[name] = nil
    return v
  end

  local function resolve_num(name)
    name = (name or ""):lower()
    if memo_num[name] then
      return memo_num[name]
    end
    local expr = resolve_expr(name, true)
    if not expr then
      return nil
    end
    local num = try_eval_numeric(expr)
    memo_num[name] = num
    return num
  end

  local function replace_token(name, numeric)
    local rep = numeric and resolve_num(name) or resolve_expr(name, false)
    return rep
  end

  local function substitute_params(text, numeric)
    local s = text or ""
    s = s:gsub("%%([%a_][%w_]*)", function(n)
      return replace_token(n, numeric) or ("%" .. n)
    end)
    return s
  end

  local changed = 0
  for i, line in ipairs(lines) do
    if not row_in_param[i] then
      local t = trim(strip_number_prefix(line))
      if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" then
        local new_line = line
        new_line = new_line:gsub("%[([^%[%]]-)%]", function(expr)
          local replaced = substitute_params(expr, apply_arith)
          if apply_arith then
            local num = try_eval_numeric(replaced)
            if num then
              return num
            end
          end
          return replaced
        end)
        new_line = new_line:gsub("%%([%a_][%w_]*)", function(n)
          local rep = replace_token(n, apply_arith)
          return rep or ("%" .. n)
        end)
        do
          local lead = new_line:match("^(%s*)") or ""
          local trail = new_line:match("(%s*)$") or ""
          local whole = trim(new_line)
          if apply_arith and whole ~= "" and whole:find(",", 1, true) == nil then
            local num = try_eval_numeric(whole)
            if num then
              new_line = lead .. num .. trail
            else
              new_line = simplify_numeric_text_fixed_point(new_line, 6)
            end
          elseif apply_arith then
            new_line = simplify_numeric_text_fixed_point(new_line, 6)
          end
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

  if apply_arith then
    for i, line in ipairs(lines) do
      if not row_in_param[i] then
        local t = trim(strip_number_prefix(line))
        if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" then
          local lead = line:match("^(%s*)") or ""
          local trail = line:match("(%s*)$") or ""
          local whole = trim(line)
          local new_line = line
          if whole ~= "" and whole:find(",", 1, true) == nil then
            local num = try_eval_numeric(whole)
            if num then
              new_line = lead .. num .. trail
            else
              new_line = simplify_numeric_text_fixed_point(line, 6)
            end
          else
            new_line = simplify_numeric_text_fixed_point(line, 6)
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

    for i, line in ipairs(lines) do
      if not row_in_param[i] then
        local t = trim(strip_number_prefix(line))
        if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" then
          local replaced = substitute_params(line, true)
          local lead = replaced:match("^(%s*)") or ""
          local trail = replaced:match("(%s*)$") or ""
          local whole = trim(replaced)
          if whole ~= "" and whole:find(",", 1, true) == nil then
            local num = try_eval_numeric(whole)
            if num then
              local new_line = lead .. num .. trail
              if new_line ~= lines[i] then
                entries[#entries + 1] = {
                  row = i,
                  before = lines[i],
                  after = new_line,
                }
                lines[i] = new_line
                changed = changed + 1
              end
            end
          end
        end
      end
    end
  end

  if changed > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
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

  local function push_item(width, cmd, desc)
    lines[#lines + 1] = string.format("%-" .. tostring(width) .. "s %s", cmd, desc)
    line_meta[#line_meta + 1] = { kind = "item", cmd = cmd, desc = desc, width = width }
  end

  push_text("IMPETUS NVIM QUICK HELP", "title")
  push_text(string.rep("=", 64), "divider")
  push_text("", "blank")
  push_text("[Core Editing]", "section")
  push_item(14, k("<localleader>h"), "Toggle right help pane (keyword help)")
  push_item(14, k("<localleader>c"), "Toggle comment/uncomment current keyword block")
  push_item(14, "dk", "Cut current block (keyword/control) into register")
  push_item(14, k("<localleader>y"), "Yank current block (keyword/control) into register")
  push_item(14, "p / P", "Put last cut block with native Vim paste")
  push_item(14, "<Tab>", "Jump to next parameter field")
  push_text("", "blank")
  push_text("[Navigation]", "section")
  push_item(14, k("<localleader>n"), "Next keyword")
  push_item(14, k("<localleader>N"), "Previous keyword")
  push_item(14, k("<localleader>f"), "Toggle fold all keyword blocks (*KEYWORD only)")
  push_item(14, k("<localleader>t"), "Toggle current keyword block fold")
  push_item(14, k("<localleader>F"), "Toggle fold all control blocks (~if/~repeat/~convert)")
  push_item(14, k("<localleader>T"), "Toggle current control block fold")
  push_item(14, k("<localleader>z"), "Toggle fold all keyword + control blocks")
  push_item(14, k("<localleader>m"), "Jump to matching ~if/~end_if (etc.)")
  push_item(14, k("<localleader>b"), "Check missing/extra control block ends")
  push_item(14, k("<localleader>u"), "Open this quick help popup")
  push_item(14, k("<localleader>o"), "Open include file in left split")
  push_text("", "blank")
  push_text("[References]", "section")
  push_item(14, "gr", "Find references of parameter under cursor")
  push_item(14, "gd", "Jump to parameter definition")
  push_item(14, k("<localleader><localleader>"), "Popup completion for ref/options")
  push_text("", "blank")
  push_text("[Main Commands]", "section")
  push_item(20, ":ImpetusInfo / :Cinfo", "Open model/file/keyword info tree")
  push_item(20, ":ImpetusGraphInfo / :Cgraph", "Open first-pass object/reference graph summary")
  push_item(20, ":ImpetusGraphRefs / :Cgr", "Show inbound/outbound refs for object under cursor")
  push_item(20, ":ImpetusGraphDeleteCheck / :Cgdel", "Check whether current object can be deleted safely")
  push_item(20, ":ImpetusHelpToggle", "Toggle right help pane")
  push_item(20, ":ImpetusReload", "Reload commands.help database")
  push_item(20, ":ImpetusLint / :Ccheck", "Run lint checks")
  push_item(20, ":clean", "Clear pairX markers only")
  push_item(20, ":clean -c", "Warm clean: remove comments/blank/noise rows (smart keep)")
  push_item(20, ":clean -a", "Full clean: pairX + warm clean + advanced prune + align PARAMETER defs")
  push_item(20, ":ImpetusReplaceParams / :re", "Replace custom params with values")
  push_item(20, ":re -a", "Replace + evaluate numeric expressions")
  push_item(20, ":ImpetusCheckBlocks", "Check unmatched ~if/~repeat/~convert pairs")
  push_item(20, ":ImpetusParamRefs", "List defs/refs of a parameter")
  push_item(20, ":ImpetusParamDef", "Jump to parameter definition")
  push_text("", "blank")
  push_text("[Short Aliases]", "section")
  push_item(20, ":help / :hp", "Open this quick help popup")
  push_item(20, ":Ch", "Toggle right help pane")
  push_item(20, ":info / :inf", "Open info pane")
  push_item(20, ":clean / :cl", "Run clean command")
  push_item(20, ":rl", "Reload commands.help database")
  push_item(20, ":chk / :Cc", "Run lint on current buffer")
  push_item(20, ":obj", "Open object registry")
  push_item(20, ":refs", "List refs of parameter under cursor")
  push_item(20, ":def", "Jump to parameter definition")
  push_item(20, ":gui", "Open GUI helper")
  push_text("", "blank")
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
        local cmd_len = #meta.cmd
        local desc_col = math.max(cmd_len, meta.width) + 1
        vim.api.nvim_buf_add_highlight(buf, -1, "impetusCheatCommand", row, 0, cmd_len)
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
    vim.notify("Impetus lint finished. Diagnostics: " .. tostring(#diagnostics), vim.log.levels.INFO)
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

  local function run_clean_command(opts)
    local args = trim(opts.args or "")
    actions.clear_directive_pair_marks()
    if args == "" then
      vim.notify("Impetus clean done. Pair markers cleared.", vim.log.levels.INFO)
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
      local aligned = align_parameter_blocks_in_buffer()

      local log_lines = {
        string.format(
          "[summary] removed=%d (warm=%d adv=%d)  PARAMETER aligned=%d",
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
      local log_path = append_operation_log("clean -a", log_lines)

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
    vim.notify("Usage: :clean | :clean -c | :clean -a", vim.log.levels.WARN)
  end

  vim.api.nvim_create_user_command("ImpetusClean", run_clean_command, { nargs = "*" })
  vim.api.nvim_create_user_command("ImpetusClear", run_clean_command, { nargs = "*" })

  vim.api.nvim_create_user_command("ImpetusReplaceParams", function(opts)
    local args = trim(opts.args or "")
    local apply_arith = args:find("%-a") ~= nil
    local changed, entries = replace_params_in_buffer(apply_arith)
    local log_lines = {
      string.format("[summary] changed=%d apply_arith=%s", changed, tostring(apply_arith)),
    }
    for _, e in ipairs(entries or {}) do
      log_lines[#log_lines + 1] = string.format("  L%-5d before: %s", e.row, trim(e.before))
      log_lines[#log_lines + 1] = string.format("         after : %s", trim(e.after))
    end
    local log_path = append_operation_log(apply_arith and "re -a" or "re", log_lines)
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
    local def = analysis.object_definition(bufnr, obj.obj_type, obj.id)
    local refs_list = analysis.object_references(bufnr, obj.obj_type, obj.id)
    local obj_items = {}
    local def_rows = {}
    if def and def.row ~= cur_row then
      obj_items[#obj_items + 1] = { kind = "def", row = def.row, col = def.col or 0, line = def.line or "", file = "" }
      def_rows[def.row] = true
    end
    for _, r in ipairs(refs_list) do
      if r.row ~= cur_row and not def_rows[r.row] then
        obj_items[#obj_items + 1] = { kind = "ref", row = r.row, col = r.col or 0, line = r.line or "", file = "" }
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
  add_alias("Ccheck", "ImpetusLint")
  add_alias("Cc", "ImpetusLint")
  add_alias("Chelp", "ImpetusCheatSheet")
  add_alias("Ch", "ImpetusHelpToggle")
  add_alias("Cregistry", "ImpetusObjects")
  add_alias("Cr", "ImpetusObjects")
  add_alias("Crefresh", "ImpetusRefresh")
  add_alias("CR", "ImpetusRefresh")
  add_alias("Creload", "ImpetusReload")
  add_alias("Crl", "ImpetusReload")
  add_alias("Cgoto", "ImpetusParamDef")
  add_alias("Cg", "ImpetusParamDef")
  add_alias("Cfind", "ImpetusParamRefs")
  add_alias("Cw", "ImpetusParamRefs")
  add_alias("Cinfo", "ImpetusInfo")
  add_alias("Ci", "ImpetusInfo")
  add_alias("Cgraph", "ImpetusGraphInfo")
  add_alias("Cgr", "ImpetusGraphRefs")
  add_alias("Cgdel", "ImpetusGraphDeleteCheck")
  add_alias("Chlprobe", "ImpetusHighlightProbe")
  add_alias("Cref", "ImpetusRefComplete")
  add_alias("Cf", "ImpetusRefComplete")
  add_alias("Copen", "ImpetusOpenGUI")
  add_alias("Co", "ImpetusOpenGUI")
  add_alias("Cgui", "ImpetusOpenGUI")
  add_alias("Re", "ImpetusReplaceParams")
  add_alias("Clean", "ImpetusClean")
  add_alias("Clear", "ImpetusClean")
  add_alias("Info", "ImpetusInfo")
  add_alias("Help", "ImpetusCheatSheet")
  add_alias("Gui", "ImpetusOpenGUI")
  add_alias("Hp", "ImpetusCheatSheet")
  add_alias("Inf", "ImpetusInfo")
  add_alias("Chk", "ImpetusLint")
  add_alias("Obj", "ImpetusObjects")
  add_alias("Refs", "ImpetusParamRefs")
  add_alias("Def", "ImpetusParamDef")
  add_alias("Rl", "ImpetusReload")
  add_alias("Cblock", "ImpetusCheckBlocks")
  add_alias("Cfoldbounds", "ImpetusFoldBounds")
  add_alias("Ctrykwfold", "ImpetusTryKeywordFold")
  add_alias("Ctryctlfold", "ImpetusTryControlFold")
  add_alias("Cfolddbg", "ImpetusFoldDoctor")
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
        local apply_arith = args:find("%f[%S]%-a%f[%s]") ~= nil or args == "-a"
        vim.schedule(function()
          local changed, entries = replace_params_in_buffer(apply_arith)
          local log_lines = {
            string.format("[summary] changed=%d apply_arith=%s", changed, tostring(apply_arith)),
          }
          for _, e in ipairs(entries or {}) do
            log_lines[#log_lines + 1] = string.format("  L%-5d before: %s", e.row, trim(e.before))
            log_lines[#log_lines + 1] = string.format("         after : %s", trim(e.after))
          end
          local log_path = append_operation_log(apply_arith and "re -a" or "re", log_lines)
          vim.notify("Impetus replace done. Updated lines: " .. tostring(changed) .. " | log: " .. vim.fn.fnamemodify(log_path, ":~:."), vim.log.levels.INFO)
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "clean" or cmd == "cl" or cmd == "clear" then
        local args = normalize_minus_variants(vim.trim(line:match("^%S+%s*(.*)$") or ""))
        vim.schedule(function()
          run_clean_command({ args = args })
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "info" or cmd == "inf" then
        vim.schedule(function()
          info.toggle_for_current()
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "help" or cmd == "hp" then
        vim.schedule(function()
          show_cheatsheet_popup()
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "gui" then
        vim.schedule(function()
          actions.open_in_gui()
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "chk" then
        vim.schedule(function()
          local diagnostics = lint.run(0)
          vim.notify("Impetus lint finished. Diagnostics: " .. tostring(#diagnostics), vim.log.levels.INFO)
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "obj" then
        vim.schedule(function()
          vim.cmd("ImpetusObjects")
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "refs" then
        vim.schedule(function()
          vim.cmd("ImpetusParamRefs")
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "def" then
        vim.schedule(function()
          vim.cmd("ImpetusParamDef")
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      elseif cmd == "rl" then
        vim.schedule(function()
          M.reload_help(false)
        end)
        return vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      end
    end
    return vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  end, { expr = true, noremap = true })
end

return M
