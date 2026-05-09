# Testing the `re -b` Command Fix

## Overview

The `re -b` command (replace parameters with full arithmetic evaluation) now properly evaluates mathematical expressions in parameter definitions and their uses. Previously, expressions like `-%Lg/2` would be substituted to `-0.05/2` but not calculated to the final value `-0.025`.

## Quick Test

### Test File
Use the provided **`test_re_b_complete.key`** file:

```
*PARAMETER
"Test re -b with mathematical expressions"
1
%Lg = 0.05
%H = -%Lg/2
%R = %Lg * 4
%Area = [%H * %R]
%Volume = %Area * 2

*MATERIAL_ELASTIC
"Steel"
1
7800,210000,0.3

*ELEMENT_SOLID
"Test Element"
1,1
1,2,3,4,5,6,7,8
```

### Expected Results After `:re -b`

| Line | Before | After | Notes |
|------|--------|-------|-------|
| 4 | `%Lg = 0.05` | `%Lg = 0.05` | Already numeric |
| 5 | `%H = -%Lg/2` | `%H = -0.025` | ✓ Fully evaluated |
| 6 | `%R = %Lg * 4` | `%R = 0.2` | ✓ Fully evaluated |
| 7 | `%Area = [%H * %R]` | `%Area = -0.005` | ✓ Chained evaluation |
| 8 | `%Volume = %Area * 2` | `%Volume = -0.01` | ✓ Chained evaluation |

### Steps to Test

1. **Open the test file**:
   ```
   :e test_re_b_complete.key
   ```

2. **Reload the plugin** (if you've modified the code):
   ```
   :ImpetusReload
   ```

3. **Run the command**:
   ```
   :re -b
   ```

4. **Check the results**:
   - View the modified lines in the buffer (they should show evaluated values)
   - Check the operations log in the message area (shows before/after for each changed line)
   - The log summary should show: `[summary] changed=5 mode=re -b`

5. **Verify operations log output**:
   You should see something like:
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

## Key Fix Details

### Root Cause
The evaluation cache (`eval_cache_func` and `eval_cache_fast`) persisted across multiple `:re -b` calls. If an expression evaluation failed once (and was cached as failed), subsequent attempts to evaluate the same expression would return the cached failure instead of re-attempting evaluation.

### Solution Applied
**Line 2659-2660 in `lua/impetus/commands.lua`**:
```lua
-- Clear evaluation caches to prevent stale cached failures from blocking re-evaluation
eval_cache_func = {}
eval_cache_fast = {}
```

This cache clearing happens at the start of `replace_params_in_buffer()`, ensuring fresh evaluation for each `:re -b` invocation.

### Also Fixed
**Line 2819**: Parameter value evaluation now uses:
```lua
if apply_arith and not value:match('^".*"$') then
  local num = eval_fn(value)
  ...
end
```
This correctly evaluates all non-quoted values (quoted strings like descriptions are preserved).

## Additional Test Cases

### Test 1: Chain Calculations (test_re_b_complete.key)
Tests that %H uses %Lg, %Area uses %H and %R, etc.
- ✓ Parameter references are substituted
- ✓ Nested expression evaluation works
- ✓ Fixed-point iteration resolves dependencies

### Test 2: Parameter-Only Evaluation (test_param_only.key)
Tests that parameters themselves are fully evaluated:
```
*PARAMETER
%Lg = 0.05
%H = -%Lg/2
%R = %Lg * 4
%Area = [%H * %R]
```
Expected after `:re -b`: All parameters have numeric values, not expressions

### Test 3: Sensor Data with Parameters (test_output_sensor_with_params.key)
Tests that parameters in data rows are substituted AND evaluated:
```
*PARAMETER
%Lg = 0.05
%H = -%Lg/2
%R = %Lg * 4

*OUTPUT_SENSOR
"Sensor 1 - Using parameter expressions"
1,1,%H,0,0
2,1,%R,0,0
```
Expected after `:re -b`:
- Row "1,1,%H,0,0" → "1,1,-0.025,0,0"
- Row "2,1,%R,0,0" → "2,1,0.2,0,0"

## Troubleshooting

### Expressions Still Not Evaluated
1. **Check plugin reload**: Run `:ImpetusReload` to ensure latest code is loaded
2. **Check impetus_nvim.log**: Look for evaluation errors
3. **Verify pattern matching**: Ensure the file uses `%ParamName` syntax (case-sensitive)
4. **Test with simple case**: Try `:re -b` on a minimal file with just one parameter

### Wrong Results or Scientific Notation Issues
1. Check if source had scientific notation (e.g., `1.5e-3`) — results may inherit that format
2. Very large or very small numbers may be formatted in scientific notation automatically
3. Look at `format_numeric_result()` logic in commands.lua (lines 1568-1594) for formatting rules

### Partial Substitution But No Evaluation
This happens when:
- Parameter substitution works (`-%Lg/2` → `-0.05/2`)
- But expression evaluation doesn't (`-0.05/2` stays as-is)

**Check**: Is `apply_arith` true for your mode? Run `:re -b` (not `:re` or `:re -ref`)

## Files Involved

- **`lua/impetus/commands.lua`**: Main implementation
  - Lines 2659-2660: Cache clearing (THE FIX)
  - Lines 2813-2825: Parameter value evaluation  
  - Lines 2937-2961: Second-pass simplification
  - Lines 1831-2106: Expression evaluation system

## Documentation

- **CLAUDE.md**: Updated with parameter substitution & arithmetic evaluation section
- **RE_B_FIX.md**: Original fix documentation
- **USER_MANUAL.md**: User-facing documentation of `:re -b` command
