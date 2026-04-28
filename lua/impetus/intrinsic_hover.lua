local M = {}

-- Cache
local cache = {
  docs = {}, -- { [name] = { type="function|variable|symbol", name="...", signature="...", desc="..." } }
  path = nil,
  mtime = -1,
}

local hover_state = {
  win = nil,
  buf = nil,
  augroup = nil,
}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Resolve intrinsic.k file path (reuses fixed logic from intrinsic.lua)
local function resolve_intrinsic_k()
  local buf_path = vim.api.nvim_buf_get_name(0)
  if buf_path and buf_path ~= "" then
    local buf_dir = vim.fn.fnamemodify(buf_path, ":p:h")
    local found = vim.fn.findfile("intrinsic.k", buf_dir .. ";")
    if found and found ~= "" then
      local abs = vim.fn.fnamemodify(found, ":p")
      if vim.fn.filereadable(abs) == 1 then
        return abs
      end
    end
  end

  local cwd = vim.fn.getcwd()
  local p1 = vim.fn.fnamemodify(cwd .. "/intrinsic.k", ":p")
  if vim.fn.filereadable(p1) == 1 then
    return p1
  end

  local src = debug.getinfo(1, "S").source or ""
  local this_file = src:gsub("^@", "")
  if this_file ~= "" then
    local plugin_root = vim.fn.fnamemodify(this_file, ":p:h:h:h")
    local sibling = vim.fn.fnamemodify(plugin_root .. "/intrinsic.k", ":p")
    if vim.fn.filereadable(sibling) == 1 then
      return sibling
    end
  end

  local alt = vim.fn.findfile("intrinsic.k", ".;")
  if alt and alt ~= "" then
    local p2 = vim.fn.fnamemodify(alt, ":p")
    if vim.fn.filereadable(p2) == 1 then
      return p2
    end
  end
  return nil
end

-- Parse intrinsic.k, extracting name-to-description mapping
local function parse_docs()
  local path = resolve_intrinsic_k()
  if not path then
    return {}
  end
  local mt = vim.fn.getftime(path)
  if cache.path == path and cache.mtime == mt then
    return cache.docs
  end

  local lines = vim.fn.readfile(path)
  local docs = {}
  local mode = nil

  for _, raw in ipairs(lines) do
    local line = trim(raw)
    local lower = line:lower()
    if lower:match("^#%s*impetus%s+intrinsic%s+function") then
      mode = "function"
    elseif lower:match("^#%s*impetus%s+intrinsic%s+variable") or lower:match("^#%s*impetus%s+intrinsic%s+constant") then
      mode = "variable"
    elseif lower:match("^#%s*impetus%s+intrinsic%s+symbol") then
      mode = "symbol"
    elseif line ~= "" and not line:match("^#") and mode then
      local name_part, desc = line:match("^([^:]+):%s*(.*)$")
      if name_part then
        name_part = trim(name_part)
        desc = trim(desc)
        -- Extract base name (strip parens, e.g. sin(x) -> sin)
        local base_name = name_part:match("^([%a_][%w_]*)") or name_part
        if base_name and base_name ~= "" then
          local lower_base = base_name:lower()
          local exact_key = name_part:lower()
          -- Store exact name (with paren args) for precise lookup, e.g. sc_jet(4)
          docs[exact_key] = {
            type = mode,
            name = exact_key,
            signature = name_part,
            desc = desc,
          }
          -- Store case-sensitive key for single-letter variables like D/V/A
          docs[name_part] = {
            type = mode,
            name = name_part,
            signature = name_part,
            desc = desc,
          }
          -- Also store base name for plain-word fallback.
          -- If the same lower_base already exists with a DIFFERENT type
          -- (e.g. "D" variable vs "d(i,j)" function), remove it to avoid
          -- ambiguity.  Same-type collisions keep the first entry.
          local existing = docs[lower_base]
          if not existing then
            docs[lower_base] = {
              type = mode,
              name = lower_base,
              signature = name_part,
              desc = desc,
            }
          elseif existing.type ~= mode then
            docs[lower_base] = nil
          end
        end
      end
    end
  end

  cache.path = path
  cache.mtime = mt
  cache.docs = docs
  return docs
end

-- Get word under cursor.
-- For intrinsic symbols like SC_jet(4), extracts the full token including
-- the parenthesised argument so that each overload gets its own hover text.
-- We do NOT use vim.fn.expand('<cword>') because the user may have extended
-- 'iskeyword' to include '-' (for keywords like *change_p-order).  Instead
-- we manually extract the token using a fixed alnum boundary so that x in
-- (x-0.05) is correctly identified as just "x".
local function word_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-based

  -- Try func(N) pattern first
  local pos = 1
  while pos <= #line do
    local s, e, name, num = line:find("([%a_][%w_]*)%s*%(%s*(%d+)%s*%)", pos)
    if not s then
      break
    end
    if col >= s - 1 and col < e then
      return name .. "(" .. num .. ")"
    end
    pos = e + 1
  end

  -- Manual word extraction with fixed alnum boundary (independent of iskeyword)
  local function is_word_char(ch)
    return ch:match("[[:alnum:]_]") ~= nil
  end

  -- col is 0-based; line:sub() is 1-based.
  local col1 = col + 1

  local start_col = col1
  while start_col > 1 and is_word_char(line:sub(start_col - 1, start_col - 1)) do
    start_col = start_col - 1
  end

  local end_col = col1
  while end_col < #line and is_word_char(line:sub(end_col + 1, end_col + 1)) do
    end_col = end_col + 1
  end

  if start_col <= end_col then
    return line:sub(start_col, end_col)
  end
  return nil
end

-- Close floating window
local function close_hover()
  if hover_state.win and vim.api.nvim_win_is_valid(hover_state.win) then
    pcall(vim.api.nvim_win_close, hover_state.win, true)
  end
  if hover_state.buf and vim.api.nvim_buf_is_valid(hover_state.buf) then
    pcall(vim.api.nvim_buf_delete, hover_state.buf, { force = true })
  end
  hover_state.win = nil
  hover_state.buf = nil
  if hover_state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, hover_state.augroup)
    hover_state.augroup = nil
  end
end

-- Wrap long description by words
local function wrap_text(text, max_width)
  local out = {}
  local line = ""
  for word in text:gmatch("%S+") do
    if #line + 1 + #word > max_width then
      out[#out + 1] = line
      line = word
    else
      line = line == "" and word or (line .. " " .. word)
    end
  end
  if line ~= "" then
    out[#out + 1] = line
  end
  return out
end

function M.show()
  -- Close existing popup first (press gh again to close)
  if hover_state.win and vim.api.nvim_win_is_valid(hover_state.win) then
    close_hover()
    return
  end

  local word = word_under_cursor()
  if not word or word == "" then
    return
  end

  local docs = parse_docs()
  local entry = docs[word]
  if not entry then
    entry = docs[word:lower()]
  end
  -- Fallback: if word looks like func(num) but docs only have func(arg_name),
  -- try the base name (e.g. dxs(1) -> dxs)
  if not entry then
    local base = word:match("^([%a_][%w_]*)%s*%(%s*%d+%s*%)")
    if base then
      entry = docs[base] or docs[base:lower()]
    end
  end
  if not entry then
    return
  end

  -- Context-sensitive: D, V, A are only intrinsic inside *BC_MOTION blocks.
  if word == "D" or word == "V" or word == "A" then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local lines_buf = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local in_bc_motion = false
    for r = row, 1, -1 do
      local line = lines_buf[r] or ""
      local kw = line:match("^%s*(%*[%w_%-]+)")
      if kw then
        in_bc_motion = (kw:upper() == "*BC_MOTION")
        break
      end
    end
    if not in_bc_motion then
      return
    end
  end

  -- Prepare display content
  local lines = {}
  local header = entry.signature
  if entry.type == "function" then
    header = header .. "  [function]"
  elseif entry.type == "variable" then
    header = header .. "  [variable]"
  else
    header = header .. "  [symbol]"
  end
  lines[#lines + 1] = header
  lines[#lines + 1] = string.rep("─", vim.fn.strdisplaywidth(header))

  if entry.desc and entry.desc ~= "" then
    local wrapped = wrap_text(entry.desc, 60)
    for _, l in ipairs(wrapped) do
      lines[#lines + 1] = l
    end
  end

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "impetus"

  -- Calculate window size
  local max_width = 0
  for _, l in ipairs(lines) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(l))
  end
  local width = math.min(max_width + 2, 68)
  local height = #lines

  -- Calculate position (prefer below cursor, above if not enough space)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local screen_row = vim.fn.screenrow()
  local screen_col = vim.fn.screencol()
  local ui = vim.api.nvim_list_uis()[1]
  local screen_height = ui and ui.height or vim.o.lines

  local opts = {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
  }

  -- Place above if not enough space below
  if screen_row + height + 3 > screen_height then
    opts.row = -height - 1
  end

  local win = vim.api.nvim_open_win(buf, false, opts)
  hover_state.win = win
  hover_state.buf = buf

  -- Highlight
  vim.api.nvim_buf_add_highlight(buf, -1, "impetusKeyword", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, -1, "impetusDivider", 1, 0, -1)

  -- Keymaps (q/Esc/gh to close popup buffer)
  for _, key in ipairs({ "q", "<Esc>", "gh" }) do
    vim.keymap.set("n", key, close_hover, { buffer = buf, silent = true, nowait = true })
  end

  -- Auto-close on cursor move/buffer switch/insert enter
  hover_state.augroup = vim.api.nvim_create_augroup("ImpetusIntrinsicHover", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave", "InsertEnter" }, {
    group = hover_state.augroup,
    buffer = vim.api.nvim_get_current_buf(),
    once = true,
    callback = close_hover,
  })
end

return M
