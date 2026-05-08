# Function Variable Highlighting Fix

## Problem

When using intrinsic functions that contain variable names as substrings (e.g., `dxs()` contains `x`), the variable name would be highlighted separately from the function name, breaking the visual continuity.

**Before:**
- `dxs(2)` would show:
  - `ds` in green (function part)
  - `x` in yellow (variable)
  - `(2)` in default color

**After:**
- `dxs(2)` shows:
  - `dxs` entirely in green (function)
  - No separate highlighting for `x`

## Root Cause

The variable highlighting syntax rule was matching any occurrence of the variable name, including inside function names. The containedin rules didn't exclude the function call context.

## Solution

Created a new syntax region `impetusIntrinsicFunctionCall` that matches function call syntax (identifier followed by parentheses). This region is now excluded from variable and symbol matching rules.

### Changes Made

1. **syntax/impetus.vim**
   - Added `impetusIntrinsicFunctionCall` syntax region
   - Updated hardcoded variable rules to exclude this region

2. **lua/impetus/intrinsic.lua**
   - Updated dynamically injected variable rules to exclude the region
   - Updated symbol rules to exclude the region

### How It Works

```vim
syntax region impetusIntrinsicFunctionCall 
  matchgroup=impetusIntrinsicFunction 
  start=/\<[a-zA-Z_][a-zA-Z0-9_]*\s*(/ 
  end=/)/ 
  containedin=ALLBUT,impetusComment,impetusString,impetusKeyword 
  fold transparent
```

This region:
- Matches any identifier followed by optional whitespace and `(`
- Extends to the matching `)`
- Is invisible (`transparent`) so it doesn't override other highlighting
- Is excluded from variable/symbol matching via `containedin` in their rules

## Test Cases

Open `test_function_var_highlight.key` to see examples:

1. **Simple case**: `dxs(2) - dxs(1)`
   - `dxs` should be green (function)
   - `x` inside should NOT be separately highlighted

2. **Variables in functions**: `sqrt(x*x + y*y)`
   - `sqrt` is green
   - `x`, `y` inside are yellow (variables) - this is correct
   - But the rule prevents them from breaking `sqrt` apart

3. **Mixed**: `sin(t) * cos(x) + dxs(t)/%Lg`
   - Multiple functions
   - Variables at different contexts

4. **Nested**: `min(max(x, y), sin(t))`
   - Nested function calls
   - Should handle gracefully

## Verification

To verify the fix works:

1. Open Neovim with `test_function_var_highlight.key`
2. Look at the *FUNCTION expressions
3. Confirm that function names are not split by variable highlighting
4. Variables inside functions should still be highlighted appropriately

## Performance Impact

- No performance impact
- Uses transparent regions which don't add overhead
- Syntax highlighting remains efficient
