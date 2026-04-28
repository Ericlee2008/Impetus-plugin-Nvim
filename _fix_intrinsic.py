import re

with open('lua/impetus/intrinsic.lua', 'r', encoding='utf-8') as f:
    content = f.read()

old = '''  vim.cmd("silent! syntax clear impetusIntrinsicFunction")
  vim.cmd("silent! syntax clear impetusIntrinsicVariable")
  vim.cmd("silent! syntax clear impetusIntrinsicSymbol")

  if #d.funcs > 0 then
    for _, fn in ipairs(d.funcs) do
      -- Functions: case-insensitive (Impetus functions are typically case-insensitive)
      vim.cmd("silent! syntax match impetusIntrinsicFunction /\\c\\<" .. vim.pesc(fn) .. "\\>\\ze\\s*(/")
    end
  end

  -- Split variables into global vars and BC_MOTION-only vars.
  local global_vars = {}
  local bc_motion_vars = {}
  for _, var in ipairs(d.vars or {}) do
    if var == "D" or var == "V" or var == "A" then
      table.insert(bc_motion_vars, var)
    else
      table.insert(global_vars, var)
    end
  end

  if #global_vars > 0 then
    -- Use syntax keyword for better reliability (avoids regex edge cases with \\<>).
    vim.cmd("silent! syntax keyword impetusIntrinsicVariable " .. table.concat(global_vars, " "))
  end

  if #bc_motion_vars > 0 then
    highlight_bc_motion_vars(vim.api.nvim_get_current_buf(), bc_motion_vars)
  end

  local symbols = d.symbols or { ops = {}, words = {} }
  local sym_words = symbols.words or {}
  local sym_ops = symbols.ops or {}

  if #sym_words > 0 then
    for _, word in ipairs(sym_words) do
      -- Symbols: case-sensitive (e.g. SC_jet is not the same as sc_jet in all contexts)
      vim.cmd("silent! syntax match impetusIntrinsicSymbol /\\<" .. vim.pesc(word) .. "\\>/")
    end
  end
  if #sym_ops > 0 then
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
      end'''

if old not in content:
    print('OLD NOT FOUND')
    # Find the actual text
    idx = content.find('vim.cmd("silent! syntax clear impetusIntrinsicFunction")')
    print('idx:', idx)
    if idx >= 0:
        print(repr(content[idx:idx+500]))
else:
    print('OLD FOUND')
