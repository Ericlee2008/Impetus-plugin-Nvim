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
  local function readable(p)
    return p and p ~= "" and vim.fn.filereadable(p) == 1
  end

  local buf_path = vim.api.nvim_buf_get_name(0)
  if buf_path and buf_path ~= "" then
    local buf_dir = vim.fn.fnamemodify(buf_path, ":p:h")
    local found = vim.fn.findfile("intrinsic.k", buf_dir .. ";")
    if found and found ~= "" then
      local abs = vim.fn.fnamemodify(found, ":p")
      if readable(abs) then
        return abs
      end
    end
  end

  local cwd = vim.fn.getcwd()
  local p1 = vim.fn.fnamemodify(cwd .. "/intrinsic.k", ":p")
  if readable(p1) then
    return p1
  end

  local src = debug.getinfo(1, "S").source or ""
  local this_file = src:gsub("^@", "")
  if this_file ~= "" then
    local plugin_root = vim.fn.fnamemodify(this_file, ":p:h:h:h")
    local sibling = vim.fn.fnamemodify(plugin_root .. "/intrinsic.k", ":p")
    if readable(sibling) then
      return sibling
    end
  end

  local alt = vim.fn.findfile("intrinsic.k", ".;")
  if readable(alt) then
    local p2 = vim.fn.fnamemodify(alt, ":p")
    if readable(p2) then
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

-- Namespace for context-sensitive intrinsic highlights (e.g. D/V/A in *BC_MOTION).
local bc_motion_ns = vim.api.nvim_create_namespace("impetus_bc_motion_intrinsics")

-- Highlight D/V/A only inside *BC_MOTION blocks.
local function highlight_bc_motion_vars(bufnr, vars)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, bc_motion_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_block = false
  local block_end = 0
  for i, line in ipairs(lines) do
    local kw = line:match("^%s*(%*[%w_%-]+)")
    if kw then
      in_block = (kw:upper() == "*BC_MOTION")
      block_end = 0
    elseif in_block then
      -- Determine block end heuristically: next blank line or next keyword-like line
      if line:match("^%s*$") or line:match("^%s*#") or line:match("^%s*$") then
        in_block = false
      else
        block_end = i
      end
    end
    if in_block then
      for _, var in ipairs(vars) do
        local esc = vim.pesc(var)
        local pos = 1
        while pos <= #line do
          local s, e = line:find("%f[%a]" .. esc .. "%f[%A]", pos)
          if not s then break end
          pcall(vim.api.nvim_buf_add_highlight, bufnr, bc_motion_ns, "impetusIntrinsicVariable", i - 1, s - 1, e)
          pos = e + 1
        end
      end
    end
  end
end

function M.apply_syntax_for_current_buffer()
  local ft = vim.bo.filetype
  if ft ~= "impetus" then
    return
  end
  if vim.b.impetus_intrinsic_applied == 1 then
    return
  end
  local d = parse()
  if not d then
    return
  end

  -- Only clear a group when we actually have new rules to apply.
  -- This preserves the hard-coded fallback keywords in syntax/impetus.vim
  -- when intrinsic.k cannot be resolved (path/cache issues).
  local has_funcs = #d.funcs > 0
  local global_vars = {}
  local bc_motion_vars = {}
  for _, var in ipairs(d.vars or {}) do
    if var == "D" or var == "V" or var == "A" then
      table.insert(bc_motion_vars, var)
    else
      table.insert(global_vars, var)
    end
  end
  local has_vars = #global_vars > 0
  local symbols = d.symbols or { ops = {}, words = {} }
  local sym_words = symbols.words or {}
  local sym_ops = symbols.ops or {}
  local has_sym_words = #sym_words > 0
  local has_sym_ops = #sym_ops > 0

  if has_funcs then
    vim.cmd("silent! syntax clear impetusIntrinsicFunction")
    for _, fn in ipairs(d.funcs) do
      -- Functions: case-insensitive (Impetus functions are typically case-insensitive)
      vim.cmd("silent! syntax match impetusIntrinsicFunction /\\c\\<" .. vim.pesc(fn) .. "\\>\\ze\\s*(/")
    end
  end

  -- Inject variables via syntax match with explicit alnum boundary.
  -- We cannot rely on \< \> because user's iskeyword may include '-' (needed
  -- for keywords like *change_p-order), which makes x-0.05 a single word.
  if has_vars then
    local added = {}
    for _, var in ipairs(global_vars) do
      if not added[var] then
        added[var] = true
        vim.cmd("silent! syntax match impetusIntrinsicVariable /\\%([[alnum:]_]\\)\\@<!" .. vim.pesc(var) .. "\\%([[alnum:]_]\\)\\@!/")
      end
    end
  end

  if #bc_motion_vars > 0 then
    highlight_bc_motion_vars(vim.api.nvim_get_current_buf(), bc_motion_vars)
  end

  if has_sym_words or has_sym_ops then
    vim.cmd("silent! syntax clear impetusIntrinsicSymbol")
    if has_sym_words then
      for _, word in ipairs(sym_words) do
        -- Symbols: case-sensitive (e.g. SC_jet is not the same as sc_jet in all contexts)
        vim.cmd("silent! syntax match impetusIntrinsicSymbol /\\<" .. vim.pesc(word) .. "\\>/")
      end
    end
    if has_sym_ops then
      for _, op in ipairs(sym_ops) do
        if op == "*" then
          vim.cmd("silent! syntax match impetusIntrinsicSymbol /\\S\\zs\\*\\ze\\S/ containedin=ALLBUT,impetusComment,impetusString,impetusKeyword")
          vim.cmd("silent! syntax match impetusIntrinsicSymbol /\\S\\s\\zs\\*\\ze\\s\\S/ containedin=ALLBUT,impetusComment,impetusString,impetusKeyword")
        elseif op == "-" then
          vim.cmd("silent! syntax match impetusIntrinsicSymbol /\\S\\s\\zs-\\ze\\s\\S/ containedin=ALLBUT,impetusComment,impetusString,impetusKeyword")
          vim.cmd("silent! syntax match impetusIntrinsicSymbol /[%)%]%w]\\zs-\\ze[%[(%w]/ containedin=ALLBUT,impetusComment,impetusString,impetusKeyword")
        else
          local lit = (op:gsub("\\", "\\\\"):gsub("/", "\\/"))
          vim.cmd("silent! syntax match impetusIntrinsicSymbol /\\V" .. lit .. "/ containedin=ALLBUT,impetusComment,impetusString,impetusKeyword")
        end
      end
    end
  end

  vim.b.impetus_intrinsic_applied = 1
end

return M
