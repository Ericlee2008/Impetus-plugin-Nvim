# Testing Bidirectional Reference Tracking

This document explains how to test the new bidirectional reference tracking feature with support for unopened files and nested includes.

## Test Scenario

The test files demonstrate a nested include structure:

```
test_main.key
  └── includes: include_b.key
       └── includes: include_c.key
```

### File Contents

**test_main.key**:
- Defines nodes 1, 2, 3
- References nodes 10-12, 20-22 (from include_b.key)
- References nodes 30-32 (from include_c.key via include_b.key)
- Uses *SET_FACE and *SET_NODE keywords

**include_b.key**:
- Includes include_c.key
- Defines nodes 10-12, 20-22

**include_c.key**:
- Defines nodes 30-32

## Testing Steps

### Test 1: Forward References (gd - Go to Definition)

1. Open `test_main.key` in Neovim
2. Position cursor on node ID 10 (in the *SET_FACE line: `1, 10, 11, 12`)
3. Press `gd` (Go to Definition)
4. Should jump to `include_b.key` and highlight the definition of node 10

**Expected Result**: Cursor moves to line with `10, 0.0, 0.1, 0.0` in include_b.key

### Test 2: Reverse References - Opened Include File

1. Open `include_b.key` in Neovim (in addition to test_main.key)
2. Position cursor on node ID 10 (definition line: `10, 0.0, 0.1, 0.0`)
3. Press `gr` (Go to References)
4. A popup should appear showing:
   - The *SET_FACE reference in test_main.key
   - Line content: `1, 10, 11, 12`
   - File tag: `[test_main.key]`

**Expected Result**: Popup shows reference from test_main.key with complete context

### Test 3: Reverse References - Unopened Include File

1. Close include_c.key (if open)
2. Open include_b.key in Neovim
3. Position cursor on node ID 30 (make sure include_c.key is NOT open as a buffer)
4. Press `gr` (Go to References)
5. A popup should appear showing:
   - The *SET_NODE reference in test_main.key
   - Line content: `NestedNodes` and `30, 31, 32`
   - File tag: `[test_main.key]`

**Expected Result**: Even though include_c.key is not opened, references are found via unopened file scanning

### Test 4: Nested Include Resolution

1. Open all three files: test_main.key, include_b.key, include_c.key
2. Position cursor on node ID 30 in include_c.key
3. Press `gr`
4. Popup should show:
   - Reference from test_main.key (via *SET_NODE line)
   - Possibly references from include_b.key if there are any

**Expected Result**: All references across the nested include chain are found

### Test 5: Multiple References

1. Open test_main.key
2. Position cursor on node ID 20 (appears in *SET_FACE: `2, 20, 21, 22`)
3. Press `gr`
4. Should see it's referenced in the same file (SET_FACE) and possibly other locations

**Expected Result**: Multiple references are listed with proper deduplication

## Implementation Details

### Key Functions

1. **`build_reverse_include_map()`** (analysis.lua:2009)
   - Builds reverse mapping: file -> list of files that include it
   - Processes all open impetus buffers recursively
   - Supports nested includes

2. **`scan_unopened_file_refs()`** (analysis.lua:1875)
   - Scans unopened files without loading them into buffers
   - Returns full reference data (row, col, keyword, line, file)
   - Handles all reference types (*SET_*, *GEOMETRY_SEED_NODE, fcn/crv, etc.)

3. **`object_references()`** (analysis.lua:2050)
   - Enhanced to include 4 sources of references:
     1. Current buffer
     2. Included files (loaded buffers)
     3. Other open buffers
     4. Files that include current file (NEW)

### Display

The `show_param_refs_popup()` function in commands.lua displays:
- Reference index number
- Reference type (def/ref)
- Filename (if cross-file)
- Line number
- Line content (trimmed)
- Keyword where reference appears

## Debugging

If references are not appearing:

1. Check `:ImpetusLint` to ensure no syntax errors
2. Verify include paths are correct (should be relative or absolute)
3. Check that file is saved (unopened file scanning reads from disk)
4. Use `:ImpetusReload` to refresh plugin state
5. Check `impetus_nvim.log` for any error messages

## Performance Notes

- Unopened file scanning reads files from disk on-demand
- References are deduplicated to avoid showing the same reference twice
- Reverse include map is built fresh each time (could be optimized with caching)
- No performance impact when only single-file editing
