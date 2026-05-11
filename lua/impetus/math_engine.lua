local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local eval_cache_fast = {}
local eval_cache_func = {}
local current_eval_error = nil

-- Round near-zero and near-integer values for cleaner output.
-- Prevents cos(90°) → 6.123e-17 and -0 → -0.
local function clean_numeric_result(v)
  if type(v) ~= "number" then
    return v
  end
  local eps = 1e-10
  if math.abs(v) < eps then
    return "0"
  end
  local rounded = math.floor(v + 0.5)
  if math.abs(v - rounded) < eps then
    return tostring(rounded)
  end
  local rounded_neg = math.ceil(v - 0.5)
  if math.abs(v - rounded_neg) < eps then
    return tostring(rounded_neg)
  end
  return nil
end

local function has_scientific_notation(src)
  local s = src or ""
  return s:find("%d[eE]%d") ~= nil or s:find("%d[eE][%+%-]%d") ~= nil
end

local function format_numeric_result(result, src)
  local src_s = src or ""
  local abs_v = math.abs(result)
  local prefer_sci = has_scientific_notation(src_s)
    or (abs_v ~= 0 and (abs_v >= 1e6 or abs_v < 1e-4))

  local cleaned = clean_numeric_result(result)
  if cleaned and (cleaned == "0" or not prefer_sci) then
    return cleaned
  end

  if prefer_sci then
    local s_num = string.format("%.8e", result)
    local mant, exp = s_num:match("^(.-)e([%+%-]%d+)$")
    if mant and exp then
      mant = mant:gsub("(%..-)0+$", "%1")
      mant = mant:gsub("%.$", "")
      exp = exp:gsub("%+", "")
      exp = exp:gsub("^(-?)0+(%d)", "%1%2")
      if exp == "" then exp = "0" end
      return mant .. "e" .. exp
    end
    return s_num
  end

  return string.format("%.15g", result)
end

-- Fast recursive-descent evaluator for simple arithmetic expressions.
-- Replaces load()/pcall() which is very slow when called thousands of times.
local function eval_expr_fast(expr)
  current_eval_error = nil
  local src = trim(expr or "")
  if src == "" then
    return nil
  end

  local cached = eval_cache_fast[src]
  if cached ~= nil then
    if type(cached) == "table" then
      if not cached.ok then
        current_eval_error = cached.error or nil
        return nil
      end
      return cached.value
    end
    -- backward compatibility
    return cached == false and nil or cached
  end

  -- Quick reject: only digits, operators, parens, dot, e/E, whitespace
  if src:find("[^%d%.eE%s%+%-%*/%^%(%)%[%]]") then
    eval_cache_fast[src] = { ok = false, error = current_eval_error }
    return nil
  end

  local s = src
  local pos = 1
  local len = #s

  local function skip_ws()
    while pos <= len and s:sub(pos, pos):match("%s") do
      pos = pos + 1
    end
  end

  local function parse_number()
    skip_ws()
    local start = pos
    while pos <= len and s:sub(pos, pos):match("[%d%.]") do
      pos = pos + 1
    end
    if pos > start then
      if pos <= len and s:sub(pos, pos):match("[eE]") then
        local ep = pos
        pos = pos + 1
        if pos <= len and s:sub(pos, pos):match("[+-]") then
          pos = pos + 1
        end
        local exp_start = pos
        while pos <= len and s:sub(pos, pos):match("%d") do
          pos = pos + 1
        end
        if pos == exp_start then
          pos = ep
        end
      end
      local n = tonumber(s:sub(start, pos - 1))
      if n then return n end
    end
    pos = start
    return nil
  end

  -- Pre-declare mutually recursive parsers so they refer to locals, not globals.
  local parse_expr, parse_term, parse_power, parse_factor

  parse_factor = function()
    skip_ws()
    local ch = s:sub(pos, pos)
    if ch == "(" then
      pos = pos + 1
      local v = parse_expr()
      skip_ws()
      if pos <= len and s:sub(pos, pos) == ")" then
        pos = pos + 1
      end
      return v
    elseif ch == "-" then
      pos = pos + 1
      local v = parse_factor()
      if v == nil then return nil end
      return -v
    elseif ch == "+" then
      pos = pos + 1
      local v = parse_factor()
      if v == nil then return nil end
      return v
    else
      return parse_number()
    end
  end

  parse_power = function()
    local left = parse_factor()
    if not left then return nil end
    skip_ws()
    while pos <= len and s:sub(pos, pos) == "^" do
      pos = pos + 1
      local right = parse_factor()
      if not right then return nil end
      if left == 0 and right < 0 then
        current_eval_error = "Zero raised to negative power in '" .. src .. "'"
        eval_cache_fast[src] = false
        return nil
      end
      left = left ^ right
      skip_ws()
    end
    return left
  end

  parse_term = function()
    local left = parse_power()
    if not left then return nil end
    skip_ws()
    while true do
      local ch = s:sub(pos, pos)
      if ch == "*" then
        pos = pos + 1
        local right = parse_power()
        if not right then return nil end
        left = left * right
      elseif ch == "/" then
        pos = pos + 1
        local right = parse_power()
        if not right then return nil end
        if right == 0 then
          current_eval_error = "Division by zero in '" .. src .. "'"
          eval_cache_fast[src] = false
          return nil
        end
        left = left / right
      else
        break
      end
      skip_ws()
    end
    return left
  end

  parse_expr = function()
    local left = parse_term()
    if not left then return nil end
    skip_ws()
    while true do
      local ch = s:sub(pos, pos)
      if ch == "+" then
        pos = pos + 1
        local right = parse_term()
        if not right then return nil end
        left = left + right
      elseif ch == "-" then
        pos = pos + 1
        local right = parse_term()
        if not right then return nil end
        left = left - right
      else
        break
      end
      skip_ws()
    end
    return left
  end

  local result = parse_expr()
  skip_ws()
  if pos <= len or not result then
    eval_cache_fast[src] = { ok = false, error = current_eval_error }
    return nil
  end

  if result ~= result then
    current_eval_error = "Result is NaN in '" .. src .. "'"
    eval_cache_fast[src] = { ok = false, error = current_eval_error }
    return nil
  end
  if result == math.huge or result == -math.huge then
    current_eval_error = "Result is infinite in '" .. src .. "'"
    eval_cache_fast[src] = { ok = false, error = current_eval_error }
    return nil
  end

  local out = format_numeric_result(result, src)
  eval_cache_fast[src] = { ok = true, value = out }
  return out
end

-- Extended evaluator supporting intrinsic math functions (sin, cos, H, min, max, etc.).
-- Used by re -b to compute final numeric values.
local MATH_FUNCS = {
  sin = function(x) return math.sin(math.rad(x)) end,
  cos = function(x) return math.cos(math.rad(x)) end,
  tan = function(x) return math.tan(math.rad(x)) end,
  asin = function(x) return math.deg(math.asin(x)) end,
  atan = function(x) return math.deg(math.atan(x)) end,
  tanh = math.tanh,
  sinr = math.sin,
  cosr = math.cos,
  tanr = math.tan,
  asinr = math.asin,
  acosr = math.acos,
  atanr = math.atan,
  exp = math.exp,
  ln = math.log,
  log = math.log,
  log10 = math.log10,
  sqrt = math.sqrt,
  abs = math.abs,
  sign = function(x) return x < 0 and -1 or 1 end,
  floor = math.floor,
  ceil = math.ceil,
  round = function(x) return math.floor(x + 0.5) end,
  mod = function(a, b) return a % b end,
  d = function(i, j) return i == j and 1 or 0 end,
  h = function(x) return x >= 0 and 1 or 0 end,
  min = function(...) return math.min(...) end,
  max = function(...) return math.max(...) end,
  erf = function(x)
    local a1, a2, a3, a4, a5 = 0.254829592, -0.284496736, 1.421413741, -1.453152027, 1.061405429
    local p = 0.3275911
    local sgn = x < 0 and -1 or 1
    x = math.abs(x)
    local t = 1 / (1 + p * x)
    local y = 1 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * math.exp(-x * x)
    return sgn * y
  end,
}

local CONSTANTS = {
  pi = math.pi,
}

local function eval_expr_with_functions(expr)
  current_eval_error = nil
  local src = trim(expr or "")
  if src == "" then
    return nil
  end

  local cached = eval_cache_func[src]
  if cached ~= nil then
    if type(cached) == "table" then
      if not cached.ok then
        current_eval_error = cached.error or nil
        return nil
      end
      return cached.value
    end
    -- backward compatibility
    return cached == false and nil or cached
  end

  -- Skip quoted strings (e.g. descriptions inside *PARAMETER rows)
  if src:match('^".*"$') then
    return nil
  end

  -- Skip keyword headers and plain identifiers (enum values like P, SI, CFD)
  if src:match("^%*") or not src:find("[%d%+%-%*/%^%(%)%[%].]") then
    return nil
  end

  local s = src
  local pos = 1
  local len = #s

  local function skip_ws()
    while pos <= len and s:sub(pos, pos):match("%s") do
      pos = pos + 1
    end
  end

  local function parse_number()
    skip_ws()
    local start = pos
    while pos <= len and s:sub(pos, pos):match("[%d%.]") do
      pos = pos + 1
    end
    if pos > start then
      if pos <= len and s:sub(pos, pos):match("[eE]") then
        local ep = pos
        pos = pos + 1
        if pos <= len and s:sub(pos, pos):match("[+-]") then
          pos = pos + 1
        end
        local exp_start = pos
        while pos <= len and s:sub(pos, pos):match("%d") do
          pos = pos + 1
        end
        if pos == exp_start then
          pos = ep
        end
      end
      local n = tonumber(s:sub(start, pos - 1))
      if n then return n end
    end
    pos = start
    return nil
  end

  local function parse_identifier()
    skip_ws()
    local start = pos
    if pos <= len and s:sub(pos, pos):match("[%a_]") then
      pos = pos + 1
      while pos <= len and s:sub(pos, pos):match("[%w_]") do
        pos = pos + 1
      end
      return s:sub(start, pos - 1)
    end
    return nil
  end

  local parse_expr, parse_term, parse_power, parse_factor

  local function parse_argument_list()
    skip_ws()
    if pos > len or s:sub(pos, pos) ~= "(" then
      return nil
    end
    pos = pos + 1
    local args = {}
    skip_ws()
    if pos <= len and s:sub(pos, pos) == ")" then
      pos = pos + 1
      return args
    end
    while true do
      local v = parse_expr()
      if v == nil then return nil end
      args[#args + 1] = v
      skip_ws()
      if pos > len then return nil end
      local ch = s:sub(pos, pos)
      if ch == ")" then
        pos = pos + 1
        return args
      elseif ch == "," then
        pos = pos + 1
      else
        return nil
      end
    end
  end

  parse_factor = function()
    skip_ws()
    if pos > len then return nil end
    local ch = s:sub(pos, pos)
    if ch == "(" then
      pos = pos + 1
      local v = parse_expr()
      skip_ws()
      if pos <= len and s:sub(pos, pos) == ")" then
        pos = pos + 1
      end
      return v
    elseif ch == "-" then
      pos = pos + 1
      local v = parse_factor()
      if v == nil then return nil end
      return -v
    elseif ch == "+" then
      pos = pos + 1
      local v = parse_factor()
      if v == nil then return nil end
      return v
    elseif ch:match("[%d%.]") then
      return parse_number()
    elseif ch:match("[%a_]") then
      local id = parse_identifier()
      if not id then return nil end
      skip_ws()
      if pos <= len and s:sub(pos, pos) == "(" then
        local args = parse_argument_list()
        if args == nil then return nil end
        local fn = MATH_FUNCS[id:lower()]
        if fn then
          local fn_result = fn(unpack(args))
          if type(fn_result) == "number" then
            if fn_result ~= fn_result then
              current_eval_error = "Function result is NaN in '" .. src .. "'"
              eval_cache_func[src] = false
              return nil
            end
            if fn_result == math.huge or fn_result == -math.huge then
              current_eval_error = "Function result is infinite in '" .. src .. "'"
              eval_cache_func[src] = false
              return nil
            end
          end
          return fn_result
        else
          current_eval_error = "Unknown function or identifier '" .. id .. "' in '" .. src .. "'"
          eval_cache_func[src] = { ok = false, error = current_eval_error }
          return nil
        end
      else
        local c = CONSTANTS[id:lower()]
        if c then
          return c
        else
          current_eval_error = "Unknown identifier '" .. id .. "' in '" .. src .. "'"
          eval_cache_func[src] = { ok = false, error = current_eval_error }
          return nil
        end
      end
    else
      current_eval_error = "Unexpected character '" .. ch .. "' in '" .. src .. "'"
      eval_cache_func[src] = { ok = false, error = current_eval_error }
      return nil
    end
  end

  parse_power = function()
    local left = parse_factor()
    if not left then return nil end
    skip_ws()
    while pos <= len and s:sub(pos, pos) == "^" do
      pos = pos + 1
      local right = parse_factor()
      if not right then return nil end
      if left == 0 and right < 0 then
        current_eval_error = "Zero raised to negative power in '" .. src .. "'"
        eval_cache_func[src] = false
        return nil
      end
      left = left ^ right
      skip_ws()
    end
    return left
  end

  parse_term = function()
    local left = parse_power()
    if not left then return nil end
    skip_ws()
    while true do
      local ch = s:sub(pos, pos)
      if ch == "*" then
        pos = pos + 1
        local right = parse_power()
        if not right then return nil end
        left = left * right
      elseif ch == "/" then
        pos = pos + 1
        local right = parse_power()
        if not right then return nil end
        if right == 0 then
          current_eval_error = "Division by zero in '" .. src .. "'"
          eval_cache_func[src] = false
          return nil
        end
        left = left / right
      else
        break
      end
      skip_ws()
    end
    return left
  end

  parse_expr = function()
    local left = parse_term()
    if not left then return nil end
    skip_ws()
    while true do
      local ch = s:sub(pos, pos)
      if ch == "+" then
        pos = pos + 1
        local right = parse_term()
        if not right then return nil end
        left = left + right
      elseif ch == "-" then
        pos = pos + 1
        local right = parse_term()
        if not right then return nil end
        left = left - right
      else
        break
      end
      skip_ws()
    end
    return left
  end

  local result = parse_expr()
  skip_ws()
  if pos <= len or result == nil then
    eval_cache_func[src] = { ok = false, error = current_eval_error }
    return nil
  end

  if result ~= result then
    current_eval_error = "Result is NaN in '" .. src .. "'"
    eval_cache_func[src] = { ok = false, error = current_eval_error }
    return nil
  end
  if result == math.huge or result == -math.huge then
    current_eval_error = "Result is infinite in '" .. src .. "'"
    eval_cache_func[src] = { ok = false, error = current_eval_error }
    return nil
  end

  local out = format_numeric_result(result, src)
  eval_cache_func[src] = { ok = true, value = out }
  return out
end

-- Partial evaluator: simplifies numeric sub-expressions while preserving
-- unknown identifiers (e.g. loop variables r1, r2).
-- Returns a number if fully evaluable, a string if partially evaluable, nil on error.
local function partial_eval_expr(expr)
  local src = trim(expr or "")
  if src == "" then return nil end
  if src:match('^".*"$') then return nil end
  if src:match("^%*") or not src:find("[%d%+%-%*/%^%(%)%[%].]") then return nil end

  local s = src
  local pos = 1
  local len = #s

  local function skip_ws()
    while pos <= len and s:sub(pos, pos):match("%s") do pos = pos + 1 end
  end

  local function parse_number()
    skip_ws()
    local start = pos
    while pos <= len and s:sub(pos, pos):match("[%d%.]") do pos = pos + 1 end
    if pos > start then
      if pos <= len and s:sub(pos, pos):match("[eE]") then
        local ep = pos
        pos = pos + 1
        if pos <= len and s:sub(pos, pos):match("[+-]") then pos = pos + 1 end
        local exp_start = pos
        while pos <= len and s:sub(pos, pos):match("%d") do pos = pos + 1 end
        if pos == exp_start then pos = ep end
      end
      local raw = s:sub(start, pos - 1)
      local n = tonumber(raw)
      if n then return { __impetus_num = true, value = n, text = raw } end
    end
    pos = start
    return nil
  end

  local function parse_identifier()
    skip_ws()
    local start = pos
    if pos <= len and s:sub(pos, pos):match("[%a_]") then
      pos = pos + 1
      while pos <= len and s:sub(pos, pos):match("[%w_]") do pos = pos + 1 end
      return s:sub(start, pos - 1)
    end
    return nil
  end

  local parse_expr, parse_term, parse_power, parse_factor

  local function parse_argument_list()
    skip_ws()
    if pos > len or s:sub(pos, pos) ~= "(" then return nil end
    pos = pos + 1
    local args = {}
    skip_ws()
    if pos <= len and s:sub(pos, pos) == ")" then
      pos = pos + 1
      return args
    end
    while true do
      local v = parse_expr()
      if v == nil then return nil end
      args[#args + 1] = v
      skip_ws()
      if pos > len then return nil end
      local ch = s:sub(pos, pos)
      if ch == ")" then
        pos = pos + 1
        return args
      elseif ch == "," then
        pos = pos + 1
      else
        return nil
      end
    end
  end

  local function is_num(v)
    return type(v) == "number" or (type(v) == "table" and v.__impetus_num == true)
  end

  local function num_value(v)
    if type(v) == "table" and v.__impetus_num == true then
      return v.value
    end
    return v
  end

  local function make_num(value, src_text)
    return {
      __impetus_num = true,
      value = value,
      text = format_numeric_result(value, src_text or src),
    }
  end

  local function fmt_val(v)
    if type(v) == "table" and v.__impetus_num == true then
      return v.text or format_numeric_result(v.value, src)
    elseif type(v) == "number" then
      return format_numeric_result(v, src)
    end
    return tostring(v)
  end

  parse_factor = function()
    skip_ws()
    if pos > len then return nil end
    local ch = s:sub(pos, pos)
    if ch == "(" then
      pos = pos + 1
      local v = parse_expr()
      skip_ws()
      if pos <= len and s:sub(pos, pos) == ")" then pos = pos + 1 end
      if v == nil then return nil end
      if is_num(v) then return v end
      return "(" .. tostring(v) .. ")"
    elseif ch == "-" then
      pos = pos + 1
      local v = parse_factor()
      if v == nil then return nil end
      if is_num(v) then
        return { __impetus_num = true, value = -num_value(v), text = "-" .. fmt_val(v) }
      end
      return "-" .. tostring(v)
    elseif ch == "+" then
      pos = pos + 1
      local v = parse_factor()
      if v == nil then return nil end
      return v
    elseif ch:match("[%d%.]") then
      return parse_number()
    elseif ch:match("[%a_]") then
      local id = parse_identifier()
      if not id then return nil end
      skip_ws()
      if pos <= len and s:sub(pos, pos) == "(" then
        local args = parse_argument_list()
        if args == nil then return nil end
        local fn = MATH_FUNCS[id:lower()]
        if fn then
          local all_num = true
          local numeric_args = {}
          local arg_texts = {}
          for _, a in ipairs(args) do
            arg_texts[#arg_texts + 1] = fmt_val(a)
            if is_num(a) then
              numeric_args[#numeric_args + 1] = num_value(a)
            else
              all_num = false
              break
            end
          end
          if all_num then
            local fn_result = fn(unpack(numeric_args))
            if type(fn_result) == "number" then
              if fn_result ~= fn_result then return nil end
              if fn_result == math.huge or fn_result == -math.huge then return nil end
              return make_num(fn_result, id .. "(" .. table.concat(arg_texts, ", ") .. ")")
            end
            return fn_result
          else
            local parts = {}
            for _, a in ipairs(args) do
              parts[#parts + 1] = fmt_val(a)
            end
            return id .. "(" .. table.concat(parts, ", ") .. ")"
          end
        else
          -- Unknown function (e.g. crv, fcn, dfcn): preserve as string
          local parts = {}
          for _, a in ipairs(args) do
            parts[#parts + 1] = fmt_val(a)
          end
          return id .. "(" .. table.concat(parts, ", ") .. ")"
        end
      else
        local c = CONSTANTS[id:lower()]
        if c then return c end
        return id
      end
    else
      return nil
    end
  end

  parse_power = function()
    local left = parse_factor()
    if left == nil then return nil end
    skip_ws()
    while pos <= len and s:sub(pos, pos) == "^" do
      pos = pos + 1
      local right = parse_factor()
      if right == nil then return nil end
      if is_num(left) and is_num(right) then
        local lnum = num_value(left)
        local rnum = num_value(right)
        if lnum == 0 and rnum < 0 then return nil end
        left = make_num(lnum ^ rnum, fmt_val(left) .. "^" .. fmt_val(right))
      else
        left = fmt_val(left) .. "^" .. fmt_val(right)
      end
      skip_ws()
    end
    return left
  end

  parse_term = function()
    local left = parse_power()
    if left == nil then return nil end
    skip_ws()
    while true do
      local ch = s:sub(pos, pos)
      if ch == "*" then
        pos = pos + 1
        local right = parse_power()
        if right == nil then return nil end
        if is_num(left) and is_num(right) then
          left = make_num(num_value(left) * num_value(right), fmt_val(left) .. "*" .. fmt_val(right))
        else
          left = fmt_val(left) .. "*" .. fmt_val(right)
        end
      elseif ch == "/" then
        pos = pos + 1
        local right = parse_power()
        if right == nil then return nil end
        if is_num(left) and is_num(right) then
          if num_value(right) == 0 then return nil end
          left = make_num(num_value(left) / num_value(right), fmt_val(left) .. "/" .. fmt_val(right))
        else
          left = fmt_val(left) .. "/" .. fmt_val(right)
        end
      else
        break
      end
      skip_ws()
    end
    return left
  end

  parse_expr = function()
    local left = parse_term()
    if left == nil then return nil end
    skip_ws()
    while true do
      local ch = s:sub(pos, pos)
      if ch == "+" then
        pos = pos + 1
        local right = parse_term()
        if right == nil then return nil end
        if is_num(left) and is_num(right) then
          left = make_num(num_value(left) + num_value(right), fmt_val(left) .. "+" .. fmt_val(right))
        else
          left = fmt_val(left) .. "+" .. fmt_val(right)
        end
      elseif ch == "-" then
        pos = pos + 1
        local right = parse_term()
        if right == nil then return nil end
        if is_num(left) and is_num(right) then
          left = make_num(num_value(left) - num_value(right), fmt_val(left) .. "-" .. fmt_val(right))
        else
          left = fmt_val(left) .. "-" .. fmt_val(right)
        end
      else
        break
      end
      skip_ws()
    end
    return left
  end

  local result = parse_expr()
  skip_ws()
  if pos <= len or result == nil then return nil end
  if is_num(result) then return num_value(result) end
  return result
end

-- Falls back to eval_expr_with_functions for expressions containing
-- function names (sin, cos, H, min, max, etc.) or constants (pi).
local function try_eval_numeric(expr)
  local prev_error = current_eval_error
  current_eval_error = nil
  local src = trim(expr or "")
  if src == "" then
    return nil
  end
  -- Skip Impetus intrinsic function calls (fcn, crv, dfcn) that have no
  -- Lua equivalent and should be preserved as-is.
  if src:find("fcn%(") or src:find("crv%(") or src:find("dfcn%(") then
    return nil
  end
  local result
  if src:find("[%a_]") then
    result = eval_expr_with_functions(expr)
  else
    result = eval_expr_fast(expr)
  end
  if not result and not current_eval_error then
    current_eval_error = prev_error
  end
  return result
end

local function is_plain_numeric_literal(expr)
  local src = trim(expr or "")
  if src == "" then
    return false
  end
  if tonumber(src) == nil then
    return false
  end
  return not src:find("[^%d%+%-%.eE]")
end

local function is_scientific_numeric_literal(expr)
  local src = trim(expr or "")
  return is_plain_numeric_literal(src) and has_scientific_notation(src)
end

-- eval_fn: optional custom evaluator function (defaults to try_eval_numeric)
local MAX_SIMPLIFY_LEN = 5000
local function simplify_numeric_text(text, eval_fn)
  local s = text or ""
  if #s > MAX_SIMPLIFY_LEN then
    return s
  end
  local eval_errors = {}
  eval_fn = eval_fn or try_eval_numeric  -- Default to try_eval_numeric if not provided

  -- Special handling for control directives: simplify only the trailing expression
  -- e.g. ~repeat %a+1  →  ~repeat 12
  local directive, rest = trim(s):match("^(~%S+)%s+(.*)$")
  if directive and rest then
    if rest:find("[%d%+%-%*/%^%(%)%[%].]") then
      local num = eval_fn(rest)
      if current_eval_error then
        current_eval_error = nil
      end
      if num then
        return directive .. " " .. num
      end
    end
    return s
  end

  -- Simplify bracket expressions
  s = s:gsub("%[([^%[%]]-)%]", function(expr)
    local num = eval_fn(expr)
    if current_eval_error then
      table.insert(eval_errors, current_eval_error)
      current_eval_error = nil
    end
    if num then
      return num
    end
    return "[" .. expr .. "]"
  end)

  -- Simplify fields: split by comma (top-level only, skip commas inside parens),
  -- evaluate each non-literal field
  local fields = {}
  local any_changed = false
  local depth = 0
  local field_start = 1
  local function process_field(field)
    local ft = trim(field)
    if ft ~= "" and not is_plain_numeric_literal(ft) and not ft:match('^".*"$') and not ft:find("=")
       and not ft:match("^~") and ft:find("[%d%+%-%*/%^%(%)%[%].]") then
      local num = eval_fn(ft)
      if current_eval_error then
        table.insert(eval_errors, current_eval_error)
        current_eval_error = nil
      end
      if num then
        local lead = field:match("^(%s*)")
        local trail = field:match("(%s*)$")
        fields[#fields + 1] = lead .. num .. trail
        any_changed = true
      else
        -- Fallback: partial simplification for expressions with unknown variables
        local simplified = partial_eval_expr(ft)
        if simplified and tostring(simplified) ~= ft then
          local lead = field:match("^(%s*)")
          local trail = field:match("(%s*)$")
          fields[#fields + 1] = lead .. tostring(simplified) .. trail
          any_changed = true
        else
          fields[#fields + 1] = field
        end
      end
    else
      fields[#fields + 1] = field
    end
  end
  for i = 1, #s do
    local ch = s:sub(i, i)
    if ch == "(" then
      depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
    elseif ch == "," and depth == 0 then
      process_field(s:sub(field_start, i - 1))
      field_start = i + 1
    end
  end
  process_field(s:sub(field_start))
  if any_changed then
    s = table.concat(fields, ",")
  end

  -- Simplify whole line if no commas
  local whole = trim(s)
  if whole ~= "" and whole:find(",", 1, true) == nil and not is_plain_numeric_literal(whole)
     and whole:find("[%d%+%-%*/%^%(%)%[%].]") then
    local num = eval_fn(whole)
    if current_eval_error then
      table.insert(eval_errors, current_eval_error)
      current_eval_error = nil
    end
    if num then
      local lead = s:match("^(%s*)")
      local trail = s:match("(%s*)$")
      return lead .. num .. trail
    end
    -- Fallback: partial simplification for expressions with unknown variables
    local simplified = partial_eval_expr(whole)
    if simplified and tostring(simplified) ~= whole then
      local lead = s:match("^(%s*)")
      local trail = s:match("(%s*)$")
      return lead .. tostring(simplified) .. trail
    end
  end

  if #eval_errors > 0 then
    current_eval_error = eval_errors[1]
  end
  return s
end

local function simplify_numeric_text_fixed_point(text, max_passes, eval_fn)
  local s = text or ""
  local passes = max_passes or 4
  for _ = 1, passes do
    local next_s = simplify_numeric_text(s, eval_fn)
    if next_s == s then
      break
    end
    s = next_s
  end
  return s
end

local MATH_API = {
  eval_expr_fast = eval_expr_fast,
  eval_expr_with_functions = eval_expr_with_functions,
  partial_eval_expr = partial_eval_expr,
  try_eval_numeric = try_eval_numeric,
  simplify_numeric_text = simplify_numeric_text,
  simplify_numeric_text_fixed_point = simplify_numeric_text_fixed_point,
  is_plain_numeric_literal = is_plain_numeric_literal,
  is_scientific_numeric_literal = is_scientific_numeric_literal,
  format_numeric_result = format_numeric_result,
  clean_numeric_result = clean_numeric_result,
  MAX_SIMPLIFY_LEN = MAX_SIMPLIFY_LEN,
  eval_cache_fast = eval_cache_fast,
  eval_cache_func = eval_cache_func,
  MATH_FUNCS = MATH_FUNCS,
  CONSTANTS = CONSTANTS,
}
setmetatable(MATH_API, {
  __index = function(_, k)
    if k == "current_eval_error" then return current_eval_error end
    return nil
  end,
  __newindex = function(_, k, v)
    if k == "current_eval_error" then current_eval_error = v end
  end,
})
return MATH_API
