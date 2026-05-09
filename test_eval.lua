#!/usr/bin/env lua
-- Test script to verify eval_expr_with_functions behavior

local math_funcs = {
  sin = function(x) return math.sin(math.rad(x)) end,
  cos = function(x) return math.cos(math.rad(x)) end,
  sqrt = math.sqrt,
  abs = math.abs,
}

local constants = {
  pi = math.pi,
}

local eval_cache = {}

local function trim(s)
  return (s or ""):match("^%s*(.-)%s*$") or ""
end

local function clean_numeric_result(result)
  local rounded = math.floor(result * 1e10 + 0.5) / 1e10
  if rounded == math.floor(rounded) then
    return tostring(math.floor(rounded))
  end
  local s = string.format("%.10f", rounded)
  s = s:gsub("0+$", ""):gsub("%.$", "")
  return s
end

local function format_numeric_result(result, src)
  local src_s = src or ""
  local cleaned = clean_numeric_result(result)
  return cleaned
end

local function eval_expr_with_functions(expr)
  local src = trim(expr or "")
  if src == "" then return nil end

  local cached = eval_cache[src]
  if cached ~= nil then
    if type(cached) == "table" then
      return cached.ok and cached.value or nil
    end
    return cached == false and nil or cached
  end

  if src:match('^".*"$') then return nil end
  if src:match("^%*") or not src:find("[%d%+%-%*/%^%(%)%[%].]") then return nil end

  local s = src
  local pos = 1
  local len = #s
  local error_msg = nil

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
      while pos <= len and s:sub(pos, pos):match("[%w_]") do pos = pos + 1 end
      return s:sub(start, pos - 1)
    end
    return nil
  end

  local parse_expr, parse_term, parse_power, parse_factor

  parse_factor = function()
    skip_ws()
    if pos > len then return nil end
    local ch = s:sub(pos, pos)
    if ch == "(" then
      pos = pos + 1
      local v = parse_expr()
      skip_ws()
      if pos <= len and s:sub(pos, pos) == ")" then pos = pos + 1 end
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
        pos = pos + 1
        skip_ws()
        if pos <= len and s:sub(pos, pos) == ")" then
          pos = pos + 1
          local fn = math_funcs[id:lower()]
          if fn then return fn() end
          error_msg = "Unknown function: " .. id
          return nil
        end
        error_msg = "Arguments not supported in test"
        return nil
      else
        local c = constants[id:lower()]
        if c then return c end
        error_msg = "Unknown identifier: " .. id
        return nil
      end
    else
      error_msg = "Unexpected character: " .. ch
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
          error_msg = "Division by zero"
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
    eval_cache[src] = { ok = false, error = error_msg }
    return nil
  end

  if result ~= result or result == math.huge or result == -math.huge then
    eval_cache[src] = { ok = false }
    return nil
  end

  local out = format_numeric_result(result, src)
  eval_cache[src] = { ok = true, value = out }
  return out
end

-- Test cases
local test_cases = {
  "-0.05/2",
  "0.05",
  "-0.025",
  "1 + 2",
  "10 * 2",
  "100 / 4",
}

print("Testing eval_expr_with_functions:")
for _, expr in ipairs(test_cases) do
  local result = eval_expr_with_functions(expr)
  print(string.format("  %-20s => %s", expr, result or "nil"))
end
