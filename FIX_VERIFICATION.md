# `re -b` Command Fix — Verification Checklist

## Fix Applied ✅

### Problem Statement
When running `:re -b` (replace parameters with full arithmetic evaluation), parameter expressions like `-%Lg/2` were being substituted to `-0.05/2` but **not** being calculated to the final value `-0.025`.

### Root Cause Identified ✅
The evaluation caches (`eval_cache_func` and `eval_cache_fast`) persist across multiple `:re -b` calls. If an expression evaluation failed once (and was cached as failed), subsequent calls would return the cached failure instead of re-attempting evaluation.

### Solution Implemented ✅
**Location**: `lua/impetus/commands.lua`, lines 2659-2660

```lua
-- Clear evaluation caches to prevent stale cached failures from blocking re-evaluation
eval_cache_func = {}
eval_cache_fast = {}
```

Added at the start of `replace_params_in_buffer()` function to ensure fresh evaluation on each `:re -b` invocation.

## Code Verification ✅

### Cache Clearing
- ✅ Line 2659-2660: Caches cleared at function entry
- ✅ Global scope variables `eval_cache_func` and `eval_cache_fast` properly reset
- ✅ Prevents stale cached failures from blocking re-evaluation

### Parameter Value Evaluation
- ✅ Line 2819: Correct condition for evaluation: `if apply_arith and not value:match('^".*"$')`
- ✅ All non-quoted values are evaluated
- ✅ Quoted strings (descriptions, titles) are preserved
- ✅ Values stored in `current_vars` for subsequent row evaluation

### Two-Pass Replacement Algorithm
- **First Pass** (lines 2810-2935):
  - ✅ Parameter value substitution
  - ✅ Arithmetic evaluation of parameter definitions
  - ✅ Storage in `current_vars`
  - ✅ Row-level arithmetic simplification

- **Second Pass** (lines 2937-2961):
  - ✅ Nested numeric expression resolution using `simplify_numeric_text_fixed_point()`
  - ✅ Fixed-point iteration (up to 4 passes) until convergence
  - ✅ Handles chained expressions (e.g., `%H` uses `%Lg`, `%Area` uses `%H` and `%R`)
  - ✅ Correctly skips:
    - Repeat block rows (preserve loop variables)
    - Include file rows (preserve file paths)
    - Function expression rows (preserve coordinate variables)

### Expression Simplification
- ✅ `simplify_numeric_text()` (lines 2400-2513): Evaluates bracket expressions and CSV fields
- ✅ `simplify_numeric_text_fixed_point()` (lines 2515-2526): Fixed-point iteration for convergence
- ✅ Bracket expressions evaluated: `[%H * %R]` → `[numeric * numeric]` → final result
- ✅ Field-by-field evaluation respects nesting (parentheses) in comma-separated data

## Documentation ✅

- ✅ **CLAUDE.md** (lines 173-203): Updated with comprehensive parameter substitution & arithmetic evaluation section
- ✅ **RE_B_FIX.md** (root cause, solution, testing): Original fix documentation
- ✅ **TEST_RE_B_FIX.md** (this session): Complete testing guide with test cases and troubleshooting

## Test Files Available ✅

| File | Purpose | Tests |
|------|---------|-------|
| `test_re_b_complete.key` | Full chain evaluation | %Lg, %H, %R, %Area, %Volume (5 parameters) |
| `test_param_only.key` | Parameter-only evaluation | %Lg, %H, %R, %Area |
| `test_output_sensor_with_params.key` | Sensor data with parameters | Parameter substitution in data rows |
| `test_sensor_debug.key` | Sensor data with parameters | Simpler version for quick testing |

## Ready for Testing ✅

### Quick Test Command
```
:e test_re_b_complete.key
:ImpetusReload
:re -b
```

### Expected Output
All 5 parameter definitions should be fully evaluated:
- `%Lg = 0.05` → `%Lg = 0.05` (already numeric)
- `%H = -%Lg/2` → `%H = -0.025` ✓
- `%R = %Lg * 4` → `%R = 0.2` ✓
- `%Area = [%H * %R]` → `%Area = -0.005` ✓
- `%Volume = %Area * 2` → `%Volume = -0.01` ✓

## Implementation Details for Future Reference

### Key Functions
| Function | Lines | Purpose |
|----------|-------|---------|
| `replace_params_in_buffer()` | 2649-2961 | Main two-pass replacement engine |
| `substitute_vars()` | - | Replaces %ParamName with current values |
| `eval_expr_with_functions()` | 1831-2106 | Full recursive expression evaluator |
| `try_eval_numeric()` | - | Lightweight evaluator for simple expressions |
| `simplify_numeric_text()` | 2400-2513 | Field-by-field and bracket evaluation |
| `simplify_numeric_text_fixed_point()` | 2515-2526 | Fixed-point iteration to convergence |
| `clean_numeric_result()` | 1544-1561 | Rounds results to integers if close |
| `format_numeric_result()` | 1568-1594 | Formats results (scientific notation when appropriate) |

### Cache Management
- **Location**: Global local variables at line 1538-1539
- **Reset**: At start of `replace_params_in_buffer()` (line 2659-2660)
- **Purpose**: Avoid redundant computation and prevent stale cached failures

### Numeric Value Validation
- **Plain numeric literals**: `is_plain_numeric_literal()` (line 2383-2397)
- **Scientific notation detection**: `has_scientific_notation()` (line 1563-1566)
- **Quoted string detection**: Pattern `value:match('^".*"$')`

## Notes for Future Maintenance

1. **Cache clearing is critical**: The global evaluation caches are intentionally cleared at function entry. Do not remove or defer this.

2. **Fixed-point iteration**: The 4-pass limit is sufficient for typical nested parameter definitions. Increase if handling deeper nesting.

3. **Selective row skipping**: The logic for skipping certain row types (repeat blocks, includes, function expressions) is intentional to preserve special syntax in those contexts.

4. **Quoted string preservation**: Uses pattern `value:match('^".*"$')` throughout to detect and preserve quoted strings.

5. **Error handling**: Uses `current_eval_error` flag and `collect_eval_error()` to track evaluation failures for reporting.

## Verification Status

| Item | Status | Notes |
|------|--------|-------|
| Problem analysis | ✅ Complete | Root cause identified as cache persistence |
| Fix implementation | ✅ Complete | Cache clearing added at function entry |
| Code review | ✅ Complete | All relevant sections verified correct |
| Documentation | ✅ Complete | CLAUDE.md updated, test guide created |
| Test files | ✅ Available | Multiple test cases ready |
| User testing | ⏳ Pending | User to run `:re -b` on test files |

---

**Status**: Ready for user testing  
**Last Updated**: Current session  
**Next Step**: User runs `:re -b` on test_re_b_complete.key and verifies all 5 parameters are fully evaluated
