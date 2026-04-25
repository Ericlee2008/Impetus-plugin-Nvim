local M = {}

local cache = {
  path = nil,
  mtime = -1,
  funcs = {},
  vars = {},
  symbols = { ops = {}, words = {} },
}

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function resolve_file()
  local cwd = vim.fn.getcwd()
  local p1 = vim.fn.fnamemodify(cwd .. "/intrinsic.k", ":p")
  if vim.fn.filereadable(p1) == 1 then
    return p1
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

local function parse()
  local path = resolve_file()
  if not path then
    cache.path = nil
    cache.funcs, cache.vars = {}, {}
    cache.symbols = { ops = {}, words = {} }
    return cache
  end
  local mt = vim.fn.getftime(path)
  if cache.path == path and cache.mtime == mt then
    return cache
  end

  local lines = vim.fn.readfile(path)
  local mode = nil
  local funcs, vars = {}, {}
  local sym_ops, sym_words = {}, {}
  local seen_f, seen_v, seen_so, seen_sw = {}, {}, {}, {}

  local function add_unique(list, seen, v)
    if v and v ~= "" and not seen[v] then
      seen[v] = true
      list[#list + 1] = v
    end
  end

  for _, raw in ipairs(lines) do
    local line = trim(raw)
    local lower = line:lower()
    if lower:match("^#%s*impetus%s+intrinsic%s+function") then
      mode = "function"
    elseif lower:match("^#%s*impetus%s+intrinsic%s+variable") or lower:match("^#%s*impetus%s+intrinsic%s+constant") then
      mode = "variable"
    elseif lower:match("^#%s*impetus%s+intrinsic%s+symbol") then
      mode = "symbol"
    elseif line ~= "" and not line:match("^#") then
      local lhs = trim((line:match("^([^:]+):") or ""))
      if lhs ~= "" then
        if mode == "function" then
          local name = lhs:match("^([%a_][%w_]*)%s*%(") or lhs:match("^([%a_][%w_]*)$")
          add_unique(funcs, seen_f, name)
        elseif mode == "variable" then
          local name = lhs:match("^([%a_][%w_]*)")
          add_unique(vars, seen_v, name)
        elseif mode == "symbol" then
          if lhs:match("^[%+%-%*/%^&|!=<>]+$") then
            add_unique(sym_ops, seen_so, lhs)
          else
            local word = lhs:match("^([%a_][%w_]*)")
            add_unique(sym_words, seen_sw, word)
          end
        end
      end
    end
  end

  table.sort(funcs)
  table.sort(vars)
  table.sort(sym_words)
  table.sort(sym_ops)

  cache.path = path
  cache.mtime = mt
  cache.funcs = funcs
  cache.vars = vars
  cache.symbols = { ops = sym_ops, words = sym_words }
  return cache
end

function M.apply_syntax_for_current_buffer()
  local ft = vim.bo.filetype
  if ft ~= "impetus" and ft ~= "kwt" then
    return
  end
  if vim.b.impetus_intrinsic_applied == 1 then
    return
  end
  local d = parse()
  if not d then
    return
  end

  if #d.funcs > 0 then
    vim.cmd("silent! syntax keyword impetusIntrinsicFunction " .. table.concat(d.funcs, " "))
  end
  if #d.vars > 0 then
    vim.cmd("silent! syntax keyword impetusIntrinsicVariable " .. table.concat(d.vars, " "))
  end
  local symbols = d.symbols or { ops = {}, words = {} }
  local sym_words = symbols.words or {}
  local sym_ops = symbols.ops or {}

  if #sym_words > 0 then
    vim.cmd("silent! syntax keyword impetusIntrinsicSymbol " .. table.concat(sym_words, " "))
  end
  if #sym_ops > 0 then
    -- Execute via Vim command to avoid Lua string escaping issues
    -- Build regex in sym_ops order
    local pattern_parts = {}
    for _, op in ipairs(sym_ops) do
      -- In Vim regex, these chars need escaping: \ ^ $ * + . ? [ ] { } ( ) |
      local escaped = op:gsub("([\\^$*+.?\\[\\]{}()|])", "\\%1")
      table.insert(pattern_parts, escaped)
    end

    local pattern = table.concat(pattern_parts, "\\|")
    vim.notify("DEBUG: sym_ops = " .. vim.inspect(sym_ops), vim.log.levels.INFO)
    vim.notify("DEBUG: pattern = " .. pattern, vim.log.levels.INFO)

    -- Use raw strings or vim.schedule to avoid escaping issues
    vim.schedule(function()
      vim.cmd("silent! syntax match impetusIntrinsicSymbol /\\m\\%(" .. pattern .. "\\)/")
    end)
  end

  vim.b.impetus_intrinsic_applied = 1
end

return M
