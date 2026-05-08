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

Use **negative lookahead** in variable matching rules to prevent variables from matching when they're part of a function name.

### Changes Made

1. **syntax/impetus.vim**
   - Added negative lookahead to hardcoded variable rules
   - Pattern: `/\%([[:alnum:]_]\)\@<!VAR\%([[:alnum:]_]*\s*(\)\@!/`
   - Means: match VAR only if NOT followed by optional word chars and `(`

2. **lua/impetus/intrinsic.lua**
   - Applied same negative lookahead to dynamically injected variable rules
   - Removed unnecessary `impetusIntrinsicFunctionCall` region exclusions

### How It Works

```vim
syntax match impetusIntrinsicVariable 
  /\%([[:alnum:]_]\)\@<!x\%([[:alnum:]_]*\s*(\)\@!/
```

The negative lookahead `\%([[:alnum:]_]*\s*(\)\@!` means:
- **Don't match** if the variable is followed by:
  - Zero or more word characters (forming function name)
  - Optional whitespace
  - Opening parenthesis `(`

### Examples

| Pattern | Matches? | Reason |
|---------|----------|--------|
| `dxs(2)` | ❌ No | `x` is part of function name before `(` |
| `sqrt(t)` | ✓ Yes | `t` is inside parentheses, not before `(` |
| `x + 5` | ✓ Yes | `x` not followed by word chars and `(` |
| `max_x(v)` | ❌ No | `x` is part of function name |

**Result:** Clean highlighting without coloring parentheses or their contents

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
