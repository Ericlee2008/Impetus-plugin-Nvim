-- Lightweight profiler that records how long it takes to fully open a .k/.key file.
-- Activate via require("impetus.profile").setup() (called from init.lua).
-- Log file: <cwd>/impetus_open_profile.log  (same convention as impetus.log)

local M = {}

local function log_path()
  return vim.fn.getcwd() .. "/impetus_open_profile.log"
end

local sessions = {}

-- Global startup timeline (not tied to a specific buffer).
local startup_events = {}
local startup_start = nil

local function hrtime_ms()
  return vim.uv.hrtime() / 1e6
end

local function get_session(buf)
  local s = sessions[buf]
  if not s then
    s = {
      start = hrtime_ms(),
      file = vim.api.nvim_buf_get_name(buf),
      events = {},
      flushed = false,
    }
    sessions[buf] = s
  end
  return s
end

local function append_raw(line)
  local f = io.open(log_path(), "a")
  if f then
    f:write(line .. "\n")
    f:close()
  end
end

local function mark(buf, name)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local s = get_session(buf)
  if s.flushed then return end
  local t = hrtime_ms() - s.start
  s.events[#s.events + 1] = { name = name, t = t }
  -- Immediate write so we still capture events even if final flush never runs.
  local fname = vim.fn.fnamemodify(s.file, ":t")
  append_raw(string.format("[live] %s | buf=%d | +%.2fms | %s",
    fname ~= "" and fname or "<unnamed>", buf, t, name))
end

local function flush(buf)
  local s = sessions[buf]
  if not s or s.flushed then return end
  s.flushed = true

  if #s.events == 0 then
    sessions[buf] = nil
    return
  end

  local file_short = vim.fn.fnamemodify(s.file, ":t")
  local lc = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_line_count(buf) or 0
  local total = s.events[#s.events].t

  local lines = {}
  lines[#lines + 1] = string.format(
    "=== %s | %s | %d lines | total=%.1fms ===",
    os.date("%Y-%m-%d %H:%M:%S"), file_short, lc, total
  )

  local prev = 0
  for _, ev in ipairs(s.events) do
    local delta = ev.t - prev
    lines[#lines + 1] = string.format(
      "  +%8.2fms  (Δ%7.2fms)  %s",
      ev.t, delta, ev.name
    )
    prev = ev.t
  end
  lines[#lines + 1] = ""

  local path = log_path()
  local f = io.open(path, "a")
  if f then
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
  end

  sessions[buf] = nil
end

function M.mark(label, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  mark(buf, label)
end

function M.mark_module_loaded(name)
  -- Use buffer 0 (current) if available, otherwise skip live logging.
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(buf) then
    mark(buf, "module loaded: " .. name)
  end
end

-- Startup-phase profiling (no buffer yet).
function M.startup_mark(label)
  if not startup_start then
    startup_start = hrtime_ms()
  end
  startup_events[#startup_events + 1] = {
    name = label,
    t = hrtime_ms() - startup_start,
  }
end

function M.flush_startup()
  if #startup_events == 0 then
    return
  end
  local lines = {}
  lines[#lines + 1] = string.format(
    "=== STARTUP PHASE | total=%.1fms ===",
    startup_events[#startup_events].t
  )
  local prev = 0
  for _, ev in ipairs(startup_events) do
    local delta = ev.t - prev
    lines[#lines + 1] = string.format(
      "  +%8.2fms  (Δ%7.2fms)  %s",
      ev.t, delta, ev.name
    )
    prev = ev.t
  end
  lines[#lines + 1] = ""
  local f = io.open(log_path(), "a")
  if f then
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
  end
  startup_events = {}
end

function M.log_path()
  return log_path()
end

function M.show()
  local path = log_path()
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("No profile log yet at " .. path, vim.log.levels.WARN)
    return
  end
  vim.cmd("split " .. vim.fn.fnameescape(path))
end

function M.clear()
  os.remove(log_path())
  sessions = {}
  vim.notify("Cleared " .. log_path(), vim.log.levels.INFO)
end

local function add(group, event, pattern, label)
  vim.api.nvim_create_autocmd(event, {
    group = group,
    pattern = pattern,
    callback = function(ev)
      mark(ev.buf, label)
    end,
  })
end

function M.setup()
  -- Mark the START of each event (registered before impetus's other autocmds
  -- via being placed at the very top of init.setup()).
  local g_first = vim.api.nvim_create_augroup("ImpetusProfileFirst", { clear = true })

  add(g_first, "BufReadPre",  { "*.k", "*.key" }, "BufReadPre   [start]")
  add(g_first, "BufReadPost", { "*.k", "*.key" }, "BufReadPost  [start]")
  add(g_first, "FileType",    "impetus",          "FileType     [start]")
  add(g_first, "Syntax",      "impetus",          "Syntax       [start]")
  add(g_first, "BufEnter",    { "*.k", "*.key" }, "BufEnter     [start]")
  add(g_first, "BufWinEnter", { "*.k", "*.key" }, "BufWinEnter  [start]")

  -- Mark the END of each event (registered after impetus's autocmds via vim.schedule).
  vim.schedule(function()
    local g_last = vim.api.nvim_create_augroup("ImpetusProfileLast", { clear = true })

    add(g_last, "BufReadPost", { "*.k", "*.key" }, "BufReadPost  [done]")
    add(g_last, "FileType",    "impetus",          "FileType     [done]")
    add(g_last, "Syntax",      "impetus",          "Syntax       [done]")
    add(g_last, "BufEnter",    { "*.k", "*.key" }, "BufEnter     [done]")
    add(g_last, "BufWinEnter", { "*.k", "*.key" }, "BufWinEnter  [done]")

    -- Final flush: schedule fires after all sync work for this tick.
    -- defer_fn(50) catches any deferred init work (e.g. async ref_marks).
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = g_last,
      pattern = { "*.k", "*.key" },
      callback = function(ev)
        local buf = ev.buf
        vim.schedule(function()
          mark(buf, "scheduled tick (sync work done)")
          vim.defer_fn(function()
            mark(buf, "settled +50ms (UI ready)")
            flush(buf)
          end, 50)
        end)
      end,
    })
  end)

  vim.api.nvim_create_user_command("ImpetusProfileShow", function() M.show() end,
    { desc = "Open the impetus open-profile log" })
  vim.api.nvim_create_user_command("ImpetusProfileClear", function() M.clear() end,
    { desc = "Clear the impetus open-profile log" })
  vim.api.nvim_create_user_command("ImpetusProfilePath", function()
    vim.notify(log_path(), vim.log.levels.INFO)
  end, { desc = "Print the impetus open-profile log path" })
end

return M
