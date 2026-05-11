local commands = require("impetus.commands")
local math_engine = require("impetus.math_engine")
local analysis = require("impetus.analysis")
local lint = require("impetus.lint")

local trim = commands.trim
local strip_number_prefix = commands.strip_number_prefix
local parse_keyword = commands.parse_keyword
local split_keyword_blocks = commands.split_keyword_blocks
local is_comment_line = commands.is_comment_line
local is_blank_line = commands.is_blank_line
local is_comma_only_line = commands.is_comma_only_line
local is_meta_row = commands.is_meta_row

local eval_expr_fast = math_engine.eval_expr_fast
local eval_expr_with_functions = math_engine.eval_expr_with_functions
local partial_eval_expr = math_engine.partial_eval_expr
local try_eval_numeric = math_engine.try_eval_numeric
local simplify_numeric_text = math_engine.simplify_numeric_text
local simplify_numeric_text_fixed_point = math_engine.simplify_numeric_text_fixed_point
local is_plain_numeric_literal = math_engine.is_plain_numeric_literal
local is_scientific_numeric_literal = math_engine.is_scientific_numeric_literal
local format_numeric_result = math_engine.format_numeric_result
local clean_numeric_result = math_engine.clean_numeric_result
local MAX_SIMPLIFY_LEN = math_engine.MAX_SIMPLIFY_LEN
local eval_cache_fast = math_engine.eval_cache_fast
local eval_cache_func = math_engine.eval_cache_func

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
  -- If no '=' assignments found, try comma format: name, value
  if #found == 0 then
    local comma_name = t:match("^%%?([%a_][%w_]*)%s*,")
    if comma_name then
      local comma_pos = t:find(",")
      if comma_pos then
        local value = trim(t:sub(comma_pos + 1))
        -- Strip trailing description string "..." but preserve commas
        -- inside function arguments like min(1, 2).
        local desc_pos = value:find(',%s*"[^"]*"%s*,')
        if not desc_pos then
          desc_pos = value:find(',%s*"[^"]*"%s*$')
        end
        if desc_pos then
          value = trim(value:sub(1, desc_pos - 1))
        end
        if value ~= "" then
          return {{ name = comma_name, value = value }}
        end
      end
    end
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
      local desc_pos = value:find(',%s*"[^"]*"%s*,')
      if not desc_pos then
        desc_pos = value:find(',%s*"[^"]*"%s*$')
      end
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
  t = t:gsub(vim.fn.nr2char(0xFF0D), "-")
  t = t:gsub(vim.fn.nr2char(0xFE63), "-")
  t = t:gsub(vim.fn.nr2char(0x2010), "-")
  t = t:gsub(vim.fn.nr2char(0x2011), "-")
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
    if p ~= "" then
      vim.notify("Impetus: cannot read include file " .. p, vim.log.levels.WARN)
    end
    return nil
  end
  return vim.fn.readfile(p)
end

-- Simple text substitution for build_param_tables: replace %name with the
-- value already known in context.  No recursion limit here because
-- build_param_tables is a one-pass scan.
local MAX_CONTEXT_LEN = 5000
local function substitute_in_context(text, context)
  local s = text or ""
  if #s > MAX_CONTEXT_LEN then
    return s
  end
  s = s:gsub("%%([%a_][%w_]*)", function(n)
    local val = context[n]
    if val then return val end
    return "%" .. n
  end)
  if #s > MAX_CONTEXT_LEN then
    return text or ""
  end
  return s
end

local function build_param_tables(lines, file_path, visited)
  local blocks = split_keyword_blocks(lines)
  local defaults = {}
  local params = {}
  local context = {}  -- local substitution context, updated in definition order
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
          local name = a.name
          local value = substitute_in_context(a.value, context)
          context[name] = value
          if ku == "*PARAMETER" then
            params[name] = value
          else
            defaults[name] = value
          end
        end
      end
    elseif ku == "*INCLUDE" and abs then
      local rel = parse_include_path_from_lines(lines, b.start_row, b.end_row)
      local full = resolve_include_path(abs, rel)
      local child_lines = read_lines_for_path(full)
      if child_lines then
        local child_vars = build_param_tables(child_lines, full, visited)
        -- Merge child params into current context so subsequent params in
        -- this file can reference include-file params.
        for k, v in pairs(child_vars) do
          context[k] = v
        end
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

  -- Clear evaluation caches to prevent stale cached failures from blocking re-evaluation
  math_engine.eval_cache_func = {}
  math_engine.eval_cache_fast = {}
  local function collect_eval_error(row, expr)
    if math_engine.current_eval_error then
      table.insert(math_errors, { row = row, expr = expr or "", reason = math_engine.current_eval_error })
      math_engine.current_eval_error = nil
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
      -- If we hit another top-level keyword (not nested *TABLE/*END_TABLE),
      -- the *FUNCTION block implicitly ends (missing *END_FUNCTION).
      if t:match("^%*[%u%d_%-]+") and not t:match("^%*TABLE%f[%A]")
         and not t:match("^%*END_TABLE%f[%A]") then
        in_function = false
        function_data_count = 0
      elseif not t:match("^%*") and t ~= "" and t:sub(1, 1) ~= "#"
         and t:sub(1, 1) ~= "$" and not t:match('^".*"$') then
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

  local MAX_SUBST_LEN = 5000

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
    if #s > MAX_SUBST_LEN then
      cycle_detected = true
      cycle_params["__overflow__"] = true
      return text
    end
    return s
  end

  local changed = 0
  for i, line in ipairs(lines) do
    if cycle_detected then break end
    -- Periodic GC to prevent memory pressure on large files
    if i % 1000 == 0 then
      collectgarbage("collect")
    end
    local is_param_row = row_in_param[i]

    -- Update current_vars when we hit a parameter definition row
    if is_param_row then
      local assignments = parse_assignments_from_line(line)
      for _, a in ipairs(assignments) do
        local name = a.name
        local value = a.value
        -- Substitute vars in the RHS so stored value is already resolved
        local before_subst = value
        value = substitute_vars(value)
        if cycle_detected then break end
        -- Evaluate arithmetic expressions in parameter values, but keep pure
        -- scientific-notation literals available for later text substitution.
        if apply_arith and not value:match('^".*"$') and not is_scientific_numeric_literal(value) then
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
    local is_include_row = row_in_include[i]
    local do_arith = apply_arith and not is_function_expr and not is_repeat_data and not is_include_row

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
                -- Partial simplification: try to simplify even if full eval failed
                -- (loop variables like r1, r2 are preserved as unknown identifiers)
                local simplified = partial_eval_expr(replaced)
                if simplified then
                  return simplified
                end
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
                  -- Skip evaluation for quoted strings and pure scientific
                  -- notation literals so original formatting is preserved.
                  if not full_val:match('^".*"$') and not is_scientific_numeric_literal(full_val) then
                    local num = eval_fn(full_val)
                    collect_eval_error(i, full_val)
                    if num then
                      new_line = new_line:sub(1, e) .. num .. tail
                    end
                  end
                end
              end
            end
          end
          -- Simplify numeric expressions in all arithmetic lines
          -- Skip only parameter rows in re -b mode (handled separately)
          if do_arith and not (mode == "all" and is_param_row) then
            local simplified = simplify_numeric_text_fixed_point(new_line, 4, eval_fn)
            if simplified ~= new_line then
              new_line = simplified
            end
            collect_eval_error(i, new_line)
          elseif is_function_expr and apply_arith then
            -- For *FUNCTION expression rows: only do partial evaluation
            -- (replace pure numeric sub-expressions while preserving variables
            -- and unknown function calls like smooth_d, crv, fcn).
            local simplified = partial_eval_expr(new_line)
            if simplified and simplified ~= new_line then
              new_line = simplified
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
  end

  -- Second pass for apply_arith: resolve nested numeric expressions
  -- Parameter definition rows are skipped (already handled in first pass).
  if not cycle_detected and apply_arith then
    for i, line in ipairs(lines) do
      -- Periodic GC to prevent memory pressure on large files
      if i % 1000 == 0 then
        collectgarbage("collect")
      end
      -- Skip only: ~repeat blocks, *INCLUDE rows, and *FUNCTION expression rows
      -- For re -b: DO simplify parameter rows (they may have had params replaced)
      local skip_simplify = repeat_block_rows[i] or row_in_include[i] or function_expr_rows[i]
      -- Parameter definition rows are already handled in the first pass;
      -- simplify_numeric_text on parameter rows produces false errors
      -- (e.g. 'R11 = 0' is not a math expression).
      if row_in_param[i] then
        skip_simplify = true
      end
      if not skip_simplify then
        local t = trim(strip_number_prefix(line))
        if t ~= "" and t:sub(1, 1) ~= "#" and t:sub(1, 1) ~= "$" then
          local new_line = simplify_numeric_text_fixed_point(line, 4, eval_fn)
          collect_eval_error(i, line)
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
    require("impetus.clean_engine").align_parameter_blocks_in_buffer()
  end

  if changed > 0 then
    refresh_buffer_analysis(buf)
  end

  return changed, entries
end

return {
  replace_params_in_buffer = replace_params_in_buffer,
  build_param_tables = build_param_tables,
  parse_assignments_from_line = parse_assignments_from_line,
  substitute_in_context = substitute_in_context,
  parse_include_path_from_lines = parse_include_path_from_lines,
  resolve_include_path = resolve_include_path,
  read_lines_for_path = read_lines_for_path,
  normalize_minus_variants = normalize_minus_variants,
  expand_all_repeats = expand_all_repeats,
  find_matching_end_repeat = find_matching_end_repeat,
  expand_repeat_block = expand_repeat_block,
  refresh_buffer_analysis = refresh_buffer_analysis,
}
