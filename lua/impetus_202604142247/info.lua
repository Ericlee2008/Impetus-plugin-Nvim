local M = {}

local state = {
  pane = nil,
  ns_static = vim.api.nvim_create_namespace("ImpetusInfoStatic"),
  ns_active = vim.api.nvim_create_namespace("ImpetusInfoActive"),
  ns_selected = vim.api.nvim_create_namespace("ImpetusInfoSelected"),
  user_closed = true,
}

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_number_prefix(line)
  return ((line or ""):gsub("^%s*%d+%.%s*", ""))
end

local function parse_keyword(line)
  local normalized = trim(strip_number_prefix(line))
  return normalized:match("^(%*[%w_%-]+)")
end

local function parse_parameter_name(line)
  local t = trim(strip_number_prefix(line or ""))
  if t == "" then
    return nil
  end
  local name = t:match("^%%?([%a_][%w_]*)%s*=")
  if not name or name == "" then
    return nil
  end
  return name
end

local function is_comment_or_empty(line)
  local t = trim(line or "")
  if t == "" then
    return true
  end
  local c = t:sub(1, 1)
  return c == "#" or c == "$"
end

local function file_ext(path)
  local p = (path or ""):lower()
  return p:match("%.([a-z0-9_]+)$")
end

local function is_text_include_file(path)
  local ext = file_ext(path)
  return ext == "k" or ext == "key"
end

local function parse_include_path_from_data_line(line)
  local t = trim(strip_number_prefix(line))
  if t == "" then
    return nil
  end
  -- Strip trailing inline comments.
  t = trim((t:gsub("%s[#$].*$", "")))
  if t == "" then
    return nil
  end

  -- Prefer quoted path.
  local q = t:match('"(.-)"')
  if q and q ~= "" then
    return trim(q:gsub("%s[#$].*$", ""))
  end

  -- Prefer explicit Windows absolute path with extension.
  local wabs = t:match("([A-Za-z]:[\\/][^,%s]+%.[A-Za-z0-9_]+)")
  if wabs and wabs ~= "" then
    return trim(wabs)
  end

  -- Prefer Unix/relative style path with extension.
  local relf = t:match("([%w%._%-%/\\]+%.[A-Za-z0-9_]+)")
  if relf and relf ~= "" then
    return trim(relf)
  end

  -- Fallback: first non-empty CSV token.
  for token in t:gmatch("([^,]+)") do
    local v = trim(token)
    if v ~= "" then
      return v
    end
  end
  return nil
end

local function resolve_include(base_file, rel)
  if not rel or rel == "" then
    return nil
  end
  local rel_norm = rel:gsub("\\", "/")
  if rel_norm:match("^[A-Za-z]:/") or rel_norm:match("^/") then
    return vim.fn.fnamemodify(rel_norm, ":p")
  end
  local base_dir = vim.fn.fnamemodify(base_file, ":p:h")
  return vim.fn.fnamemodify(base_dir .. "/" .. rel_norm, ":p")
end

local function parse_lines(lines)
  local out = {
    keywords = {}, -- { keyword, row, occ }
    includes = {}, -- { rel, row }
    parameters = {}, -- { name, row, scope }
    total_lines = #(lines or {}),
  }
  local occ_map = {}
  local current_kw = nil

  local i = 1
  while i <= #lines do
    local raw = lines[i] or ""
    local kw = parse_keyword(raw)
    if kw then
      local ku = kw:upper()
      current_kw = ku
      occ_map[ku] = (occ_map[ku] or 0) + 1
      out.keywords[#out.keywords + 1] = { keyword = kw, row = i, occ = occ_map[ku] }
      if ku == "*INCLUDE" then
        local inline = trim(strip_number_prefix(raw)):match("^%*[%w_%-]+%s*,?%s*(.+)$")
        local rel = parse_include_path_from_data_line(inline or "")

        local function looks_invalid_include(v)
          local t = trim(v or "")
          if t == "" then
            return true
          end
          if t:match("^[A-Za-z]$") then
            return true
          end
          return false
        end

        if looks_invalid_include(rel) then
          rel = nil
        end

        if not rel then
          local j = i + 1
          while j <= #lines do
            local r = lines[j] or ""
            if parse_keyword(r) then
              break
            end
            if not is_comment_or_empty(r) then
              -- Hard-priority for the classic two-line form:
              -- *INCLUDE
              -- mesh.k
              local raw_line = trim(strip_number_prefix(r))
              local q = raw_line:match('"(.-)"')
              if q and q ~= "" then
                rel = trim(q)
              else
                rel = trim((raw_line:match("^([^,%s]+)") or raw_line))
              end

              if looks_invalid_include(rel) then
                rel = parse_include_path_from_data_line(r)
              end

              if rel and rel ~= "" and not looks_invalid_include(rel) then
                break
              end
            end
            j = j + 1
          end
        end
        if rel and rel ~= "" then
          out.includes[#out.includes + 1] = { rel = rel, row = i }
        end
      end
    elseif current_kw == "*PARAMETER" or current_kw == "*PARAMETER_DEFAULT" then
      local name = parse_parameter_name(raw)
      if name then
        out.parameters[#out.parameters + 1] = { name = name, row = i, scope = current_kw }
      end
    end
    i = i + 1
  end

  local uniq = {}
  for _, k in ipairs(out.keywords) do
    uniq[k.keyword] = true
  end
  out.total_keywords = #out.keywords
  out.unique_keywords = vim.tbl_count(uniq)
  out.total_parameters = #out.parameters
  return out
end

local function read_file_lines(path)
  if not path or path == "" then
    return nil
  end
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return vim.fn.readfile(path)
end

local function build_tree(path, lines, visited)
  local abs = vim.fn.fnamemodify(path, ":p")
  if visited[abs] then
    return {
      path = abs,
      cycle = true,
      parsed = { keywords = {}, includes = {}, parameters = {}, total_keywords = 0, unique_keywords = 0, total_parameters = 0, total_lines = 0 },
      children = {},
    }
  end
  visited[abs] = true

  local parsed = parse_lines(lines or {})
  local node = {
    path = abs,
    parsed = parsed,
    children = {},
  }

  for _, inc in ipairs(parsed.includes) do
    local full = resolve_include(abs, inc.rel)
    if full and is_text_include_file(full) then
      local child_lines = read_file_lines(full)
      if child_lines then
        node.children[#node.children + 1] = build_tree(full, child_lines, visited)
      else
        node.children[#node.children + 1] = {
          path = full,
          missing = true,
          parsed = { keywords = {}, includes = {}, parameters = {}, total_keywords = 0, unique_keywords = 0, total_parameters = 0, total_lines = 0 },
          children = {},
        }
      end
    else
      node.children[#node.children + 1] = {
        path = full or inc.rel,
        skipped = true,
        parsed = { keywords = {}, includes = {}, parameters = {}, total_keywords = 0, unique_keywords = 0, total_parameters = 0, total_lines = 0 },
        children = {},
      }
    end
  end

  visited[abs] = nil
  return node
end

local function current_keyword_under_cursor(buf, win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local kw = nil
  local start_row = nil
  for r = row, 1, -1 do
    local k = parse_keyword(lines[r] or "")
    if k then
      kw = k
      start_row = r
      break
    end
  end
  if not kw then
    return nil, nil
  end
  local ku = kw:upper()
  local occ = 0
  for i = 1, start_row do
    local k = parse_keyword(lines[i] or "")
    if k and k:upper() == ku then
      occ = occ + 1
    end
  end
  return kw, occ
end

local function focus_main_first_keyword(pane)
  if not pane then
    return
  end
  local main_win = pane.main_win
  local main_buf = pane.source_buf
  if not (main_win and vim.api.nvim_win_is_valid(main_win)) then
    return
  end
  if not (main_buf and vim.api.nvim_buf_is_valid(main_buf)) then
    main_buf = vim.api.nvim_win_get_buf(main_win)
  end
  if not (main_buf and vim.api.nvim_buf_is_valid(main_buf)) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(main_buf, 0, -1, false)
  local row = nil
  for i, line in ipairs(lines) do
    if parse_keyword(line or "") then
      row = i
      break
    end
  end
  if not row then
    return
  end
  pcall(vim.api.nvim_set_current_win, main_win)
  pcall(vim.api.nvim_win_set_cursor, main_win, { row, 0 })
end

local function set_selected_line(pane, lnum)
  if not pane or not pane.buf or not vim.api.nvim_buf_is_valid(pane.buf) then
    return
  end
  pane.selected_lnum = lnum
  vim.api.nvim_buf_clear_namespace(pane.buf, state.ns_selected, 0, -1)
  if lnum and lnum >= 0 then
    vim.api.nvim_buf_add_highlight(pane.buf, state.ns_selected, "ImpetusInfoSelected", lnum, 0, -1)
  end
end

local function clear_selected_line(pane)
  set_selected_line(pane, nil)
end

local function set_statusline_text(pane, text)
  if not pane or not pane.buf or not vim.api.nvim_buf_is_valid(pane.buf) then
    return
  end
  local value = text and text ~= "" and (" [Selected] " .. text) or " Impetus Info "
  vim.b[pane.buf].impetus_info_statusline = value
  if pane.win and vim.api.nvim_win_is_valid(pane.win) then
    vim.wo[pane.win].statusline = "%{%get(b:,'impetus_info_statusline',' Impetus Info ')%}"
  end
end

local function selected_label_from_target(target)
  if not target then
    return nil
  end
  local path = target.path and vim.fn.fnamemodify(target.path, ":t") or nil
  if target.keyword and path and path ~= "" then
    return path .. "  |  " .. target.keyword
  end
  if path and path ~= "" then
    return path
  end
  return nil
end

local function find_window_showing_path(path)
  local target = vim.fn.fnamemodify(path or "", ":p")
  if target == "" then
    return nil
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_buf_is_valid(b)
        and vim.b[b].impetus_info_buffer ~= 1
        and vim.b[b].impetus_help_buffer ~= 1
        and vim.w[w].impetus_nav_window ~= 1
      then
        local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":p")
        if buf_path == target then
          return w
        end
      end
    end
  end
  return nil
end

local function restore_main_cursor_or_first(pane)
  if not pane then
    return
  end
  local rc = pane.return_cursor
  if rc and rc.win and vim.api.nvim_win_is_valid(rc.win) then
    local b = vim.api.nvim_win_get_buf(rc.win)
    if b == rc.buf and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_set_current_win, rc.win)
      if rc.row and rc.row >= 1 then
        pcall(vim.api.nvim_win_set_cursor, rc.win, { rc.row, rc.col or 0 })
      end
      return
    end
  end
  focus_main_first_keyword(pane)
end

local function find_main_window_candidate()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_buf_is_valid(b) then
        if vim.b[b].impetus_info_buffer ~= 1 and vim.b[b].impetus_help_buffer ~= 1
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
      if vim.api.nvim_buf_is_valid(b) and vim.b[b].impetus_info_buffer == 1 then
        local main_win, main_buf = find_main_window_candidate()
        state.pane = {
          win = w,
          buf = b,
          source_buf = main_buf,
          source_win = main_win,
          main_win = main_win,
          open_file = main_buf and vim.api.nvim_buf_get_name(main_buf) or "",
          line_targets = {},
          keyword_active_lines = {},
          nav_win = nil,
          return_cursor = nil,
        }
        return state.pane
      end
    end
  end
  return nil
end

local function ensure_pane(source_buf, source_win)
  local pane = state.pane
  if pane and pane.buf and vim.api.nvim_buf_is_valid(pane.buf) and pane.win and vim.api.nvim_win_is_valid(pane.win) then
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

  local ok_split = pcall(vim.cmd, "leftabove vsplit")
  if not ok_split then
    return nil
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = "impetus"
  vim.bo[buf].syntax = "impetus"
  vim.b[buf].impetus_info_buffer = 1
  vim.w[win].impetus_info_window = 1

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false
  vim.api.nvim_win_set_width(win, 74)

  state.pane = {
    win = win,
    buf = buf,
    source_buf = source_buf,
    source_win = source_win,
    main_win = source_win,
    open_file = vim.api.nvim_buf_get_name(source_buf),
    line_targets = {},
    keyword_active_lines = {},
    nav_win = nil,
    return_cursor = nil,
    selected_lnum = nil,
  }
  set_statusline_text(state.pane, nil)

  local function jump_from_info()
    local p = state.pane
    if not p or not vim.api.nvim_win_is_valid(p.win) then
      return
    end
    local lnum = vim.api.nvim_win_get_cursor(p.win)[1] - 1
    local target = p.line_targets and p.line_targets[lnum] or nil
    if not target then
      return
    end
    set_selected_line(p, lnum)
    set_statusline_text(p, selected_label_from_target(target))

    local path = target.path and vim.fn.fnamemodify(target.path, ":p") or nil
    local source_path = ""
    if p.source_buf and vim.api.nvim_buf_is_valid(p.source_buf) then
      source_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(p.source_buf), ":p")
    end

    local dst = nil
    if path ~= "" and source_path ~= "" and path ~= source_path then
      local existing = find_window_showing_path(path)
      if existing and vim.api.nvim_win_is_valid(existing) then
        dst = existing
      end
      if p.source_win and vim.api.nvim_win_is_valid(p.source_win) then
        local src_buf = vim.api.nvim_win_get_buf(p.source_win)
        local cc = vim.api.nvim_win_get_cursor(p.source_win)
        p.return_cursor = {
          win = p.source_win,
          buf = src_buf,
          row = cc[1],
          col = cc[2],
        }
      end
      if not dst and p.nav_win and vim.api.nvim_win_is_valid(p.nav_win) then
        dst = p.nav_win
      elseif not dst then
        local base_win = (p.source_win and vim.api.nvim_win_is_valid(p.source_win)) and p.source_win or p.main_win
        if base_win and vim.api.nvim_win_is_valid(base_win) then
          vim.api.nvim_set_current_win(base_win)
        end
        local ok = pcall(vim.cmd, "leftabove vsplit")
        if ok then
          p.nav_win = vim.api.nvim_get_current_win()
          vim.w[p.nav_win].impetus_nav_window = 1
          dst = p.nav_win
        end
      end
    end

    if not dst then
      dst = (p.source_win and vim.api.nvim_win_is_valid(p.source_win)) and p.source_win or vim.api.nvim_get_current_win()
    end
    vim.api.nvim_set_current_win(dst)

    if path and path ~= "" and vim.fn.filereadable(path) == 1 then
      local cur = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
      if cur ~= path then
        vim.cmd("edit " .. vim.fn.fnameescape(path))
      end
    end
    if target.row and target.row > 0 then
      vim.api.nvim_win_set_cursor(dst, { target.row, 0 })
      vim.cmd("normal! zz")
    end
  end

  vim.keymap.set("n", "<CR>", jump_from_info, { buffer = buf, silent = true, desc = "Jump to keyword/file" })
  vim.keymap.set("n", "<2-LeftMouse>", jump_from_info, { buffer = buf, silent = true, desc = "Jump to keyword/file" })
  vim.keymap.set("n", "<LeftRelease>", function()
    local p = state.pane
    if not p or not vim.api.nvim_win_is_valid(p.win) then
      return
    end
    local lnum = vim.api.nvim_win_get_cursor(p.win)[1] - 1
    local target = p.line_targets and p.line_targets[lnum] or nil
    if target then
      set_selected_line(p, lnum)
      set_statusline_text(p, selected_label_from_target(target))
    end
  end, { buffer = buf, silent = true, desc = "Select info item" })

  if vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  end
  return state.pane
end

local function set_lines(buf, lines)
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
end

local function highlight_numbers(buf, lnum, line)
  local s = 1
  while true do
    local a, b = line:find("%d+%.?%d*", s)
    if not a then
      break
    end
    vim.api.nvim_buf_add_highlight(buf, state.ns_static, "impetusNumber", lnum, a - 1, b)
    s = b + 1
  end
end

local function render(source_buf, source_win)
  local pane = ensure_pane(source_buf, source_win)
  if not pane or not vim.api.nvim_buf_is_valid(pane.buf) then
    return
  end

  local root_file = vim.api.nvim_buf_get_name(source_buf)
  if root_file == "" then
    set_lines(pane.buf, { "No file path for current buffer." })
    return
  end

  local root_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local root = build_tree(root_file, root_lines, {})
  local function aggregate_model_stats(node, acc, is_root)
    acc = acc or { total = 0, uniq = {}, parameters = 0, lines = 0, include_files = 0 }
    if node and node.parsed then
      acc.total = acc.total + (node.parsed.total_keywords or 0)
      acc.parameters = acc.parameters + (node.parsed.total_parameters or 0)
      acc.lines = acc.lines + (node.parsed.total_lines or 0)
      for _, k in ipairs(node.parsed.keywords or {}) do
        if k.keyword then
          acc.uniq[k.keyword:upper()] = true
        end
      end
    end
    for _, ch in ipairs((node and node.children) or {}) do
      if not ch.skipped then
        acc.include_files = acc.include_files + 1
      end
      aggregate_model_stats(ch, acc, false)
    end
    return acc
  end
  local model_stats = aggregate_model_stats(root, nil, true)
  local model_unique = 0
  for _ in pairs(model_stats.uniq) do
    model_unique = model_unique + 1
  end

  local lines = {}
  local marks = {}
  local line_targets = {}
  local keyword_active_lines = {}

  local function add_line(text, opts)
    lines[#lines + 1] = text
    local lnum = #lines - 1
    if opts and opts.stripe then
      marks[#marks + 1] = { group = "impetusInfoStripe", lnum = lnum, col_start = 0, col_end = -1 }
    end
    if opts and opts.group then
      marks[#marks + 1] = { group = opts.group, lnum = lnum, col_start = opts.col_start or 0, col_end = opts.col_end or -1 }
    end
    if opts and opts.stats_col_start then
      marks[#marks + 1] = {
        group = "impetusInfoStats",
        lnum = lnum,
        col_start = opts.stats_col_start,
        col_end = opts.stats_col_end or -1,
      }
    end
    if opts and opts.target then
      line_targets[lnum] = opts.target
    end
    if opts and opts.active_key then
      keyword_active_lines[opts.active_key] = keyword_active_lines[opts.active_key] or {}
      keyword_active_lines[opts.active_key][#keyword_active_lines[opts.active_key] + 1] = lnum
    end
    return lnum
  end

  local function add_stats_table_row(left_label, left_value, right_label, right_value)
    local text = string.format("%-22s %-10s    %-22s %-10s", left_label, tostring(left_value), right_label, tostring(right_value))
    local lnum = add_line(text)
    local ll = text:find(left_label, 1, true)
    local lv = text:find(tostring(left_value), (ll or 1) + #left_label, true)
    local rl = text:find(right_label, (lv or 1) + tostring(left_value):len(), true)
    local rv = text:find(tostring(right_value), (rl or 1) + #right_label, true)
    if ll then
      marks[#marks + 1] = { group = "impetusInfoStatLabel", lnum = lnum, col_start = ll - 1, col_end = ll - 1 + #left_label }
    end
    if lv then
      marks[#marks + 1] = { group = "impetusInfoNumber", lnum = lnum, col_start = lv - 1, col_end = lv - 1 + #tostring(left_value) }
    end
    if rl then
      marks[#marks + 1] = { group = "impetusInfoStatLabel", lnum = lnum, col_start = rl - 1, col_end = rl - 1 + #right_label }
    end
    if rv then
      marks[#marks + 1] = { group = "impetusInfoNumber", lnum = lnum, col_start = rv - 1, col_end = rv - 1 + #tostring(right_value) }
    end
  end

  add_line("MODEL INFORMATION", { group = "impetusHeader" })
  add_line(string.rep("-", 60), { group = "impetusDivider" })
  add_line("File: " .. vim.fn.fnamemodify(root.path, ":t"), { group = "impetusFieldName", target = { path = root.path, row = 1 } })
  add_stats_table_row("Keywords (model)", model_stats.total, "Unique types", model_unique)
  add_stats_table_row("Included files", model_stats.include_files, "Parameters", model_stats.parameters)
  add_stats_table_row("Total lines", model_stats.lines, "Root file lines", root.parsed.total_lines or 0)
  add_line("")

  add_line("FILE TREE", { group = "impetusOptions" })
  add_line(string.rep("-", 60), { group = "impetusDivider" })

  local function pad_right_stats(left, right, min_gap)
    local total_width = 70
    local gap = min_gap or 2
    local left_w = vim.fn.strdisplaywidth(left)
    local right_w = vim.fn.strdisplaywidth(right)
    if left_w + gap + right_w >= total_width then
      return left .. string.rep(" ", gap) .. right
    end
    return left .. string.rep(" ", total_width - left_w - right_w) .. right
  end

  local function fmt_stats(kw, uniq, lines_count)
    return string.format("kw:%3d  uniq:%3d  lines:%9d", kw or 0, uniq or 0, lines_count or 0)
  end

  local file_tree_row_index = 0

  local function emit_file_node(node, prefix, is_last)
    local marker = (is_last and "└─ " or "├─ ")
    local rail = (is_last and "   " or "│  ")
    local name = vim.fn.fnamemodify(node.path or "?", ":t")
    local left = prefix .. marker .. name
    local right
    if node.cycle then
      right = "[cycle]"
    elseif node.missing then
      right = "[missing]"
    elseif node.skipped then
      right = "[skipped non-k]"
    else
      right = fmt_stats(node.parsed.total_keywords, node.parsed.unique_keywords, node.parsed.total_lines)
    end
    file_tree_row_index = file_tree_row_index + 1
    local rendered = pad_right_stats(left, right, 3)
    local stats_col = rendered:find(right, 1, true)
    add_line(rendered, {
      group = "impetusFieldName",
      stripe = (file_tree_row_index % 2 == 1),
      stats_col_start = stats_col and (stats_col - 1) or nil,
      stats_col_end = stats_col and (stats_col - 1 + #right) or nil,
      target = { path = node.path, row = 1 },
    })
    local branch_pos = rendered:find(name, 1, true)
    if branch_pos and branch_pos > 1 then
      marks[#marks + 1] = {
        group = "impetusInfoBranch",
        lnum = #lines - 1,
        col_start = 0,
        col_end = branch_pos - 1,
      }
    end
    local child_prefix = prefix .. rail
    for i, ch in ipairs(node.children or {}) do
      emit_file_node(ch, child_prefix, i == #node.children)
    end
  end
  emit_file_node(root, "", true)
  add_line("")

  add_line("KEYWORD TREE", { group = "impetusDefault" })
  add_line(string.rep("-", 60), { group = "impetusDivider" })

  local function emit_keywords_for_file(node, prefix, is_last)
    if node.skipped then
      return
    end
    local function has_keywords(n)
      if n.skipped then
        return false
      end
      if n.parsed and n.parsed.keywords and #n.parsed.keywords > 0 then
        return true
      end
      for _, ch in ipairs(n.children or {}) do
        if has_keywords(ch) then
          return true
        end
      end
      return false
    end
    if not has_keywords(node) then
      return
    end

    local marker = (is_last and "└─ " or "├─ ")
    local name = vim.fn.fnamemodify(node.path or "?", ":t")
    local file_text = prefix .. marker .. name
    local file_lnum = add_line(file_text, { group = "impetusFieldName", target = { path = node.path, row = 1 } })
    local name_pos = file_text:find(name, 1, true)
    if name_pos and name_pos > 1 then
      marks[#marks + 1] = {
        group = "impetusInfoBranch",
        lnum = file_lnum,
        col_start = 0,
        col_end = name_pos - 1,
      }
    end
    local inner_prefix = prefix .. (is_last and "   " or "│  ")

    for _, k in ipairs(node.parsed.keywords or {}) do
      local text = inner_prefix .. "├─ " .. k.keyword
      local lnum = add_line(text, {
        group = "impetusInfoKeyword",
        target = { path = node.path, row = k.row, keyword = k.keyword },
        active_key = (vim.fn.fnamemodify(node.path, ":p") .. "::" .. k.keyword:upper() .. "::" .. tostring(k.occ or 1)),
      })
      local pos = text:find(k.keyword, 1, true)
      if pos then
        if pos > 1 then
          marks[#marks + 1] = { group = "impetusInfoBranch", lnum = lnum, col_start = 0, col_end = pos - 1 }
        end
        marks[#marks + 1] = { group = "impetusInfoKeyword", lnum = lnum, col_start = pos - 1, col_end = pos - 1 + #k.keyword }
      end
    end

    for i, ch in ipairs(node.children or {}) do
      emit_keywords_for_file(ch, inner_prefix, i == #node.children)
    end
  end
  emit_keywords_for_file(root, "", true)

  set_lines(pane.buf, lines)
  vim.api.nvim_buf_clear_namespace(pane.buf, state.ns_static, 0, -1)
  vim.api.nvim_buf_clear_namespace(pane.buf, state.ns_active, 0, -1)

  for _, m in ipairs(marks) do
    vim.api.nvim_buf_add_highlight(pane.buf, state.ns_static, m.group, m.lnum, m.col_start, m.col_end)
  end
  for i, line in ipairs(lines) do
    highlight_numbers(pane.buf, i - 1, line)
  end

  pane.source_buf = source_buf
  pane.source_win = source_win
  if (not pane.main_win or not vim.api.nvim_win_is_valid(pane.main_win))
    and source_win and vim.api.nvim_win_is_valid(source_win)
    and vim.w[source_win].impetus_nav_window ~= 1
    and vim.w[source_win].impetus_child_window ~= 1
  then
    pane.main_win = source_win
  end
  pane.open_file = vim.fn.fnamemodify(root_file, ":p")
  pane.line_targets = line_targets
  pane.keyword_active_lines = keyword_active_lines
  set_selected_line(pane, pane.selected_lnum)
  set_statusline_text(pane, pane.selected_lnum and selected_label_from_target(line_targets[pane.selected_lnum]) or nil)
  M.sync_active()
end

function M.sync_active()
  local pane = state.pane
  if not pane or not pane.buf or not vim.api.nvim_buf_is_valid(pane.buf) then
    return
  end
  if not pane.source_buf or not vim.api.nvim_buf_is_valid(pane.source_buf) then
    return
  end
  if not pane.source_win or not vim.api.nvim_win_is_valid(pane.source_win) then
    return
  end

  local kw, occ = current_keyword_under_cursor(pane.source_buf, pane.source_win)
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(pane.source_buf), ":p")
  vim.api.nvim_buf_clear_namespace(pane.buf, state.ns_active, 0, -1)
  if not kw or path == "" then
    return
  end

  local key = path .. "::" .. kw:upper() .. "::" .. tostring(occ or 1)
  local lns = pane.keyword_active_lines and pane.keyword_active_lines[key] or nil
  if not lns then
    return
  end
  local first_active = nil
  for _, lnum in ipairs(lns) do
    if not first_active then
      first_active = lnum
    end
    vim.api.nvim_buf_add_highlight(pane.buf, state.ns_active, "impetusHelpActiveLine", lnum, 0, -1)
    local line = vim.api.nvim_buf_get_lines(pane.buf, lnum, lnum + 1, false)[1] or ""
    local p = line:find(kw, 1, true)
    if p then
      vim.api.nvim_buf_add_highlight(pane.buf, state.ns_active, "impetusHelpActiveParam", lnum, p - 1, p - 1 + #kw)
    end
  end
  if first_active and pane.win and vim.api.nvim_win_is_valid(pane.win) then
    pcall(vim.api.nvim_win_call, pane.win, function()
      vim.api.nvim_win_set_cursor(pane.win, { first_active + 1, 0 })
      vim.cmd("normal! zz")
    end)
  end
end

function M.open_for_current()
  state.user_closed = false
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  if vim.b[buf].impetus_info_buffer == 1 then
    return
  end
  render(buf, win)
end

function M.close_for_current(manual)
  if manual ~= false then
    state.user_closed = true
  end
  local pane = state.pane or recover_existing_pane()
  if not pane then
    return
  end
  if pane.nav_win and vim.api.nvim_win_is_valid(pane.nav_win) then
    pcall(vim.api.nvim_win_close, pane.nav_win, true)
  end
  if pane.win and vim.api.nvim_win_is_valid(pane.win) then
    pcall(vim.api.nvim_win_close, pane.win, true)
  end
  state.pane = nil
end

function M.is_open()
  local pane = state.pane or recover_existing_pane()
  return pane and pane.win and vim.api.nvim_win_is_valid(pane.win) or false
end

function M.toggle_for_current()
  if M.is_open() then
    M.close_for_current()
  else
    M.open_for_current()
  end
end

function M.get_debug_state()
  local pane = state.pane or recover_existing_pane()
  if not pane then
    return nil
  end
  return {
    win = pane.win,
    buf = pane.buf,
    source_win = pane.source_win,
    source_buf = pane.source_buf,
    main_win = pane.main_win,
    nav_win = pane.nav_win,
    open_file = pane.open_file,
    user_closed = state.user_closed,
  }
end

function M.setup()
  local group = vim.api.nvim_create_augroup("ImpetusInfoPane", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    group = group,
    callback = function(ev)
      local pane = state.pane
      if not pane then
        if not state.user_closed then
          local ft = vim.bo[ev.buf].filetype
          local cur_win = vim.api.nvim_get_current_win()
          if (ft == "impetus" or ft == "kwt")
            and vim.b[ev.buf].impetus_info_buffer ~= 1
            and vim.b[ev.buf].impetus_child_buffer ~= 1
            and vim.w[cur_win].impetus_nav_window ~= 1
            and vim.w[cur_win].impetus_child_window ~= 1
            and vim.g.impetus_opening_child ~= 1
          then
            render(ev.buf, cur_win)
          end
        end
        return
      end
      if vim.v.exiting ~= vim.NIL and tonumber(vim.v.exiting) and tonumber(vim.v.exiting) ~= 0 then
        return
      end
      if vim.g.impetus_fast_nav == 1 then
        return
      end
      if vim.g.impetus_opening_child == 1 then
        return
      end
      if vim.b[ev.buf].impetus_info_buffer == 1 then
        return
      end
      if vim.b[ev.buf].impetus_child_buffer == 1 then
        return
      end
      local ft = vim.bo[ev.buf].filetype
      if ft ~= "impetus" and ft ~= "kwt" then
        clear_selected_line(pane)
        return
      end

      local cur_win = vim.api.nvim_get_current_win()
      local is_nav = (vim.w[cur_win].impetus_nav_window == 1)
      local is_child = (vim.w[cur_win].impetus_child_window == 1)

      -- Child/nav windows must not replace the main/source ownership, otherwise
      -- closing them will accidentally close info/help panes.
      if not is_nav and not is_child and vim.b[ev.buf].impetus_child_buffer ~= 1 then
        pane.source_buf = ev.buf
        pane.source_win = cur_win
        if not pane.main_win or not vim.api.nvim_win_is_valid(pane.main_win) then
          pane.main_win = cur_win
        end
      end
      local cur_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ":p")
      clear_selected_line(pane)
      if pane.open_file ~= cur_path then
        render(ev.buf, pane.source_win or cur_win)
      else
        M.sync_active()
      end
    end,
  })

  -- Do not close info pane on BufWipeout.
  -- Child buffers can be wiped independently; lifecycle is tied to main window.

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local pane = state.pane
      if not pane then
        return
      end
      local closed = tonumber(ev.match)
      if not closed then
        return
      end
      if pane.nav_win and closed == pane.nav_win then
        pane.nav_win = nil
        vim.schedule(function()
          restore_main_cursor_or_first(pane)
        end)
        return
      end
      if pane.main_win and closed == pane.main_win then
        vim.schedule(function()
          M.close_for_current(false)
        end)
      elseif pane.win and closed == pane.win then
        state.pane = nil
      end
    end,
  })

  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      M.close_for_current(false)
    end,
  })
end

return M
