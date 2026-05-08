local M = {}

local analysis = require("impetus.analysis")

-- Namespace for extmarks.
local ns_id = vim.api.nvim_create_namespace("impetus_ref_marks")

-- Namespace for scope-pair directive highlights.
local scope_hl_ns = vim.api.nvim_create_namespace("impetus_scope_pair_hl")

-- 24-color high-contrast palette (same as directive pair marks from ,m)
local pair_palette = {
  "#ff6b6b", "#ffd166", "#06d6a0", "#4cc9f0", "#f72585", "#b8f35d",
  "#f4a261", "#9b5de5", "#00f5d4", "#f15bb5", "#fee440", "#00bbf9",
  "#e76f51", "#90be6d", "#43aa8b", "#577590", "#ff8fab", "#7bdff2",
  "#c77dff", "#ffb703", "#80ed99", "#48cae4", "#ff9770", "#a0c4ff",
}

local function pair_hl_group(pair_idx)
  local n = ((pair_idx - 1) % #pair_palette) + 1
  return ("impetusDirectivePairMark%d"):format(n)
end

local function find_directive_keyword_range(raw_line)
  local prefix, kw = raw_line:match("^(%s*%d*%.?%s*)(~[%w_]+)")
  if kw then
    local start_col = #prefix
    return start_col, start_col + #kw
  end
  return nil, nil
end

local function update_scope_pair_highlights(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local pairs = analysis.collect_directive_pairs(lines)
  vim.api.nvim_buf_clear_namespace(buf, scope_hl_ns, 0, -1)

  for idx, pair in ipairs(pairs) do
    local hl_group = pair_hl_group(idx)

    local rows = { pair.start_row }
    for _, mid in ipairs(pair.mid_rows or {}) do
      rows[#rows + 1] = mid
    end
    rows[#rows + 1] = pair.end_row

    for _, row in ipairs(rows) do
      local raw_line = lines[row] or ""
      local sc, ec = find_directive_keyword_range(raw_line)
      if sc then
        pcall(vim.api.nvim_buf_set_extmark, buf, scope_hl_ns, row - 1, sc, {
          end_col = ec,
          hl_group = hl_group,
          priority = 150,
        })
      end
    end
  end
end

-- Debounce timers per buffer.
local timers = {}

-- Global toggle state.
local enabled = true

-- Highlight groups (created once).
local hl_setup_done = false
local function ensure_highlights()
  if hl_setup_done then
    return
  end
  hl_setup_done = true
  vim.api.nvim_set_hl(0, "ImpetusDefMark", { underline = true, sp = "#00ff88" })
  vim.api.nvim_set_hl(0, "ImpetusRefMark", { underline = true, sp = "#00aaff" })
  vim.api.nvim_set_hl(0, "ImpetusRefMarkDead", { undercurl = true, sp = "#ff4444" })
end

-- Clear all extmarks in the namespace for a buffer.
function M.clear(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, scope_hl_ns, 0, -1)
end

-- Compute the end column for an ID token starting at `col` (0-based).
local function id_end_col(line, col)
  local s = col + 1
  local e = s
  while e <= #line do
    local ch = line:sub(e, e)
    if ch:match("[%d%w_%.%-]") then
      e = e + 1
    else
      break
    end
  end
  return math.max(e - 1, s)
end

-- Maximum buffer line count for which ref_marks will run synchronously.
local MAX_LINES_SYNC = 50000

-- Core update: read the buffer index and place underlines.
function M.update(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not enabled then
    M.clear(bufnr)
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  -- Only for impetus filetype.
  local ft = vim.bo[bufnr].filetype
  if ft ~= "impetus" then
    return
  end
  -- Skip huge buffers to avoid hanging on open.
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count > MAX_LINES_SYNC then
    return
  end

  ensure_highlights()
  M.clear(bufnr)

  local ok, idx = pcall(analysis.build_buffer_index, bufnr)
  if not ok or not idx then
    return
  end

  -- Cross-file index: includes defs/refs from *INCLUDE files and other buffers.
  local cross_ok, cross = pcall(analysis.build_cross_file_object_index, bufnr)
  if not cross_ok or not cross then
    cross = { defs = {}, refs = {} }
  end

  -- Track occupied (row, col) positions to avoid duplicate marks.
  -- Def marks take precedence over ref marks at the same spot.
  local occupied = {}
  local function is_occupied(row, col)
    local key = row .. ":" .. col
    return occupied[key] == true
  end
  local function set_occupied(row, col)
    occupied[row .. ":" .. col] = true
  end

  local marks = {}

  -- Helper to add a mark entry.
  local function add_mark(row, col, end_col, hl_group)
    -- row is 1-based; extmark needs 0-based.
    local r0 = row - 1
    marks[#marks + 1] = {
      row = r0,
      col = col,
      end_col = end_col,
      hl_group = hl_group,
    }
  end

  -- 1) Definitions that are also referenced (anywhere) → green underline.
  for obj_type, defs in pairs(idx.object_defs or {}) do
    local cross_refs = cross.refs[obj_type] or {}
    local local_refs = (idx.object_refs or {})[obj_type] or {}
    for idv, info in pairs(defs) do
      if cross_refs[idv] or local_refs[idv] then
        local line = info.line or ""
        local ec = id_end_col(line, info.col)
        add_mark(info.row, info.col, ec, "ImpetusDefMark")
        set_occupied(info.row, info.col)
      end
    end
  end

  -- 2) References that have a definition (anywhere) → blue underline.
  --    References without a definition anywhere → red undercurl (dead ref).
  for obj_type, refs in pairs(idx.object_refs or {}) do
    local cross_defs = cross.defs[obj_type] or {}
    for idv, list in pairs(refs) do
      local has_def = cross_defs[idv] ~= nil
      local hl = has_def and "ImpetusRefMark" or "ImpetusRefMarkDead"
      for _, info in ipairs(list) do
        if not is_occupied(info.row, info.col) then
          local line = info.line or ""
          local ec = id_end_col(line, info.col)
          add_mark(info.row, info.col, ec, hl)
          set_occupied(info.row, info.col)
        end
      end
    end
  end

  -- Batch place extmarks.
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, m.row, m.col, {
      end_col = m.end_col,
      hl_group = m.hl_group,
      priority = 100,
    })
  end

  -- Scope-pair directive highlights (if / repeat / convert / scope families).
  update_scope_pair_highlights(bufnr)
end

-- Debounced wrapper for update.
function M.update_debounced(bufnr, delay)
  delay = delay or 300
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if timers[bufnr] then
    timers[bufnr]:stop()
    timers[bufnr]:close()
    timers[bufnr] = nil
  end
  local timer = vim.loop.new_timer()
  timers[bufnr] = timer
  timer:start(delay, 0, vim.schedule_wrap(function()
    if timers[bufnr] == timer then
      timers[bufnr] = nil
    end
    pcall(timer.close, timer)
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.update(bufnr)
    end
  end))
end

-- Global toggle.
function M.toggle()
  enabled = not enabled
  if enabled then
    vim.notify("Impetus reference marks: ON", vim.log.levels.INFO)
    -- Update all visible impetus buffers.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local ft = vim.bo[buf].filetype
        if ft == "impetus" then
          M.update(buf)
        end
      end
    end
  else
    vim.notify("Impetus reference marks: OFF", vim.log.levels.INFO)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        M.clear(buf)
      end
    end
  end
  return enabled
end

-- Setup autocmds.
function M.setup()
  local group = vim.api.nvim_create_augroup("ImpetusRefMarks", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    pattern = { "*.k", "*.key" },
    callback = function(ev)
      if enabled then
        M.update(ev.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = { "*.k", "*.key" },
    callback = function(ev)
      if enabled then
        M.update_debounced(ev.buf, 400)
      end
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      hl_setup_done = false
      ensure_highlights()
      if enabled then
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(buf) then
            local ft = vim.bo[buf].filetype
            if ft == "impetus" then
              M.update(buf)
            end
          end
        end
      end
    end,
  })
end

return M
