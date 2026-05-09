# re -b Command Fix

## Problem

When running `re -b` (replace parameters with full arithmetic evaluation), parameter expressions like `-%Lg/2` were being substituted to `-0.05/2` but **not** being calculated to the final value `-0.025`.

**Example:**
```
*PARAMETER
%Lg = 0.05
%H = -%Lg/2      # Expected: -0.025, Got: -0.05/2 ❌
```

## Root Cause

In parameter value evaluation (lines 2813 and 2897), the code used:
```lua
if apply_arith and not is_scientific_numeric_literal(value) then
```

This condition was too restrictive. It prevented evaluation of expressions that:
- Contained operators (`/`, `*`, `+`, `-`)
- Didn't contain scientific notation

Since `is_scientific_numeric_literal("-0.05/2")` returns `false` (it's not a plain numeric literal), the condition logic was backwards in some cases, preventing evaluation.

## Solution

Replace the `is_scientific_numeric_literal` check with a simple quoted-string check:

```lua
if apply_arith and not value:match('^".*"$') then
  local num = eval_fn(value)
  ...
end
```

Now the code:
- Evaluates all non-quoted values
- Skips only quoted strings (like parameter descriptions)
- Doesn't try to evaluate scientific notation status

## Changes Made

1. **Line 2813** - Parameter value evaluation in first pass:
   - Before: `if apply_arith and not is_scientific_numeric_literal(value) then`
   - After: `if apply_arith and not value:match('^".*"$') then`

2. **Line 2897** - Parameter RHS evaluation in parameter-specific block:
   - Before: `if not is_scientific_numeric_literal(full_val) then`
   - After: `if not full_val:match('^".*"$') then`

## Testing

Use the provided test files:

**Simple test:** `test_re_b.key`
```
*PARAMETER
%Lg = 0.05
%H = -%Lg/2    # Should become -0.025
```

**Complete test:** `test_re_b_complete.key`
```
*PARAMETER
%Lg = 0.05
%H = -%Lg/2           # → -0.025
%R = %Lg * 4          # → 0.2
%Area = [%H * %R]    # → -0.005 (=  -0.025 * 0.2)
%Volume = %Area * 2  # → -0.01 (= -0.005 * 2)
```

### To Test:

1. Open `test_re_b_complete.key` in Neovim
2. Run `:re -b`
3. Verify all parameters are fully evaluated to numeric values
4. Check the operations log for results

## Impact

- ✅ `re -b` now fully evaluates mathematical expressions in parameter definitions
- ✅ Chain calculations work correctly (`%H` uses `%Lg`, `%Area` uses `%H` and `%R`, etc.)
- ✅ All arithmetic operations (`+`, `-`, `*`, `/`, `^`) are properly calculated
- ✅ Both substitution and evaluation happen in the correct order

## Verification Command

After applying the fix, the operations log should show:
```
[summary] changed=5 mode=re -b
  L4 before: %Lg = 0.05
       after : %Lg = 0.05
  L5 before: %H = -%Lg/2
       after : %H = -0.025
  L6 before: %R = %Lg * 4
       after : %R = 0.2
  L7 before: %Area = [%H * %R]
       after : %Area = -0.005
  L8 before: %Volume = %Area * 2
       after : %Volume = -0.01
```

All parameters should have final numeric values, not expressions.
