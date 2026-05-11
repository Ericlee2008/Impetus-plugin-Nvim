local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function has_scientific_notation(src)
  local s = src or ""
  return s:find("%d[eE]%d") ~= nil or s:find("%d[eE][%+%-]%d") ~= nil
end

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

print("500e6 -> " .. format_numeric_result(500000000, "500e6"))
print("300e6 -> " .. format_numeric_result(300000000, "300e6"))
print("1.0e6 -> " .. format_numeric_result(1000000, "1.0e6"))
print("500000000 -> " .. format_numeric_result(500000000, ""))
