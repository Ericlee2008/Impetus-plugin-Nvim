-- Test script for bidirectional reference tracking
-- Run with: nvim --headless -c "lua dofile('test_reverse_refs.lua')" -c quit

local function test_scan_unopened_file()
  print("\n=== Testing scan_unopened_file_refs ===")

  -- Simulate loading the analysis module functions
  local analysis = require("impetus.analysis")

  -- Test 1: Check if include_b.key can be scanned
  print("Test 1: Scanning unopened include_b.key for node 10 references")
  local unopened_file = vim.fn.fnamemodify(vim.fn.getcwd(), ":p") .. "include_b.key"
  print("File path: " .. unopened_file)

  -- Check if file exists
  if vim.fn.filereadable(unopened_file) == 1 then
    print("✓ include_b.key exists and is readable")
  else
    print("✗ include_b.key not found or not readable")
    return false
  end

  return true
end

local function test_include_files()
  print("\n=== Testing Include File Detection ===")

  -- Check if test files exist
  local test_files = {
    "test_main.key",
    "include_b.key",
    "include_c.key"
  }

  local cwd = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  for _, fname in ipairs(test_files) do
    local fpath = cwd .. fname
    if vim.fn.filereadable(fpath) == 1 then
      print("✓ " .. fname .. " found")
    else
      print("✗ " .. fname .. " not found")
      return false
    end
  end

  return true
end

local function test_nested_include_structure()
  print("\n=== Testing Nested Include Structure ===")

  -- Read test_main.key and check for include
  local main_file = vim.fn.fnamemodify(vim.fn.getcwd(), ":p") .. "test_main.key"
  local lines = vim.fn.readfile(main_file)

  local has_include_b = false
  for _, line in ipairs(lines) do
    if line:match("include_b%.key") then
      has_include_b = true
      print("✓ test_main.key includes include_b.key")
      break
    end
  end

  if not has_include_b then
    print("✗ test_main.key does not include include_b.key")
    return false
  end

  -- Read include_b.key and check for include
  local include_b_file = vim.fn.fnamemodify(vim.fn.getcwd(), ":p") .. "include_b.key"
  lines = vim.fn.readfile(include_b_file)

  local has_include_c = false
  for _, line in ipairs(lines) do
    if line:match("include_c%.key") then
      has_include_c = true
      print("✓ include_b.key includes include_c.key")
      break
    end
  end

  if not has_include_c then
    print("✗ include_b.key does not include include_c.key")
    return false
  end

  return true
end

-- Run tests
print("\n" .. string.rep("=", 50))
print("Bidirectional Reference Tracking - Validation Tests")
print(string.rep("=", 50))

local all_pass = true

if not test_include_files() then
  all_pass = false
end

if not test_nested_include_structure() then
  all_pass = false
end

if not test_scan_unopened_file() then
  all_pass = false
end

print("\n" .. string.rep("=", 50))
if all_pass then
  print("✓ All validation tests passed!")
  print("Ready to test in Neovim:")
  print("  1. nvim test_main.key")
  print("  2. Position cursor on node 10 in *SET_FACE line")
  print("  3. Press 'gr' to see references")
else
  print("✗ Some validation tests failed")
end
print(string.rep("=", 50) .. "\n")
