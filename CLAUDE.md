# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Project Overview

**impetus.nvim** is a Neovim plugin for authoring LS-DYNA / Impetus simulation input files (`.k`, `.key`). It provides intelligent completion, real-time linting with physics sanity checks, cross-file parameter resolution, navigation, and a comprehensive IDE experience.

**Tech Stack**: Lua (Neovim plugin), Python (geometry viewer)

---

## Development Setup

### No build step required

The plugin is pure Lua and loads directly in Neovim. No build/compilation needed.

### Loading for development

Add to your `lazy.nvim` config:
```lua
{
  dir = "<absolute-path-to-repo>",
  config = function()
    require("impetus").setup({
      help_file = "<path-to>/commands.help",  -- optional: your current Impetus help
      dev_hot_reload = true,
      lint_on_save = true,
    })
  end,
}
```

Then restart Neovim or run `:Lazy reload impetus`.

### Testing the plugin in isolation

- Open any `.k` / `.key` file in Neovim (filetype is auto-detected)
- Verify completion with `<C-x><C-o>` (omnifunc) or your completion framework
- Check lint diagnostics: `:ImpetusLint` or watch realtime (if `lint_on_save = true`)
- Press `K` on any keyword or parameter for documentation

### Reload during development

With `dev_hot_reload = true` in config, the plugin reloads automatically when you save files. Otherwise, run `:ImpetusReload` manually.

---

## Codebase Architecture

### Entry Points
- **`plugin/impetus.lua`** — Plugin guard and minimal setup
- **`lua/impetus/init.lua`** — Main module initialization; calls `.setup()` and wires all submodules

### Core Modules

#### Analysis & Parsing
- **`lua/impetus/parser.lua`** — Parse keyword blocks into structured rows. Handles CSV fields, title rows, brackets, parameter references.
- **`lua/impetus/analysis.lua`** — High-level file analysis: extract keywords, find keyword ranges, build cross-file indexes for `*INCLUDE` resolution. Caches by file mtime.
- **`lua/impetus/schema.lua`** — Define keyword signatures (parameter names/types for each keyword). Loaded from `commands.help` or bundled `data/keywords.json`.

#### Validation & Linting
- **`lua/impetus/lint.lua`** — Real-time diagnostics (Error/Warning/Suspicion):
  - Unknown keywords
  - Field count mismatches
  - Enum value validation (e.g., `*UNIT_SYSTEM` unit names)
  - Physics sanity ranges (density, time steps, material IDs)
  - Control directive balance (`~if`, `~repeat`, `~convert`)
  - Parameter reference validation
  - **Key logic**: Detects optional ID row omission via `is_id_like` heuristic (first param is pure numeric or ends in `id`).

#### Completion & UI
- **`lua/impetus/complete.lua`** — Omnifunc provider for `<C-x><C-o>` completion (keywords, parameters, object IDs, enum values).
- **`lua/impetus/blink_source.lua`** — Integration with `blink.cmp`; expands keywords into templates with snippet placeholders.
- **`lua/impetus/actions.lua`** — Interactive popups (e.g., ref completion on `,,`).
- **`lua/impetus/hover.lua`** — Implements `K`-key hover documentation (keyword signature + parameter descriptions).
- **`lua/impetus/commands.lua`** — User commands (`:ImpetusLint`, `:ImpetusReload`, etc.) and editor actions (delete block, yank, comment toggle).

#### Organization & Navigation
- **`lua/impetus/info.lua`** — Info pane showing keyword details, parameter tree, with folding support.
- **`lua/impetus/side_help.lua`** — Side help pane rendering (parameter docs from schema).
- **`lua/impetus/ref_marks.lua`** — Mark object ID references inline for quick navigation.
- **`lua/impetus/graph.lua`** — Build object dependency graphs (e.g., which parts use which materials).

#### Helpers
- **`lua/impetus/config.lua`** — Configuration management. Defaults: `help_file`, `lint_on_save`, `tab_field_jump`, `dev_hot_reload`, `ref_marks`, etc.
- **`lua/impetus/highlight.lua`** — Syntax highlighting rules (keywords, parameters, values, comments).
- **`lua/impetus/store.lua`** — In-memory keyword database (loaded once from help file or bundled JSON).
- **`lua/impetus/log.lua`** — Structured operation logging (appends to `impetus_nvim.log`).
- **`lua/impetus/template.lua`** — Snippet template generation for keyword expansion.
- **`lua/impetus/snippets.lua`** — Snippet utilities and placeholder management.
- **`lua/impetus/fold.lua`** — Foldexpr for collapsing keyword blocks and control directives.
- **`lua/impetus/geometry_preview.lua`** — Launch Python viewer for model visualization (`:ImpetusPreviewGeometry`).
- **`lua/impetus/intrinsic.lua`** & **`lua/impetus/intrinsic_hover.lua`** — Built-in function documentation (functions like `sin()`, `sqrt()`, etc.).

### Syntax & Filetypes
- **`syntax/impetus.vim`** — Vim syntax rules (keywords, parameters, operators, comments).
- **`ftdetect/impetus.lua`** — Auto-detect filetype for `*.k`, `*.key`, `commands.help`.
- **`ftplugin/impetus.vim`** — Buffer-local settings (omnifunc, folding).

### Data Files
- **`data/keywords.json`** — Bundled keyword database (fallback if `commands.help` unavailable). Generated from a `commands.help` snapshot.
- **`intrinsic.k`** — Bundled intrinsic function database.

---

## Key Design Patterns

### Cross-File Resolution
Files are indexed recursively via `*INCLUDE` directives. Parameter definitions (`%param`) and object IDs (`pid`, `mid`, etc.) are collected from all included files (local-first lookup). See `analysis.lua:build_file_index()` and `analysis.lua:resolve_include_chain()`.

### Optional ID Row Detection
Many keywords have an optional single-field ID row before the multi-field data rows (e.g., `*BC_MOTION` with optional `bcid`). The lint engine detects omission via:
1. First schema parameter is `is_id_like` (pure numeric or ends in `id`).
2. First data value is **not** an ID-like value.
If both true, all data rows shift by +1 against the schema signature. See `lint.lua:check_field_counts()`.

### Hardcoded Enums
Some enums (e.g., `*UNIT_SYSTEM` units) are hardcoded tables in `lint.lua` to avoid brittle free-text parsing of `commands.help`. This is a tradeoff: maintainability for generality.

### Snippet-Based Completion
Keyword expansion inserts template with `${1:field1}`, `${2:field2}` placeholders. Neovim's snippet engine (`vim.snippet.*`) or blink.cmp handles the field-jump workflow. See `template.lua` and `blink_source.lua`.

### Async Diagnostics
Lint diagnostics are computed on-save or on-demand (`:ImpetusLint`), not in real-time background loops (for stability).

---

## Recent Improvements & Fixes

### Syntax Highlighting Fixes
1. **Intrinsic hover window (`:gh` command)**
   - Removed `filetype = "impetus"` from hover buffer (`intrinsic_hover.lua:296`)
   - Now only header/divider lines are highlighted; description text avoids spurious intrinsic variable highlighting
   
2. **Comment line detection (`syntax/impetus.vim`)**
   - Added rule for mid-line comments: `syntax match impetusComment /[#$].*/` (line 15)
   - Previously only matched line-start comments (`^`), missing inline `#` after parameter values
   - Now properly excludes all comment text from intrinsic highlighting
   
3. **Intrinsic variable/function/symbol exclusions**
   - Updated `syntax/impetus.vim` (line 33): hardcoded intrinsics now use `containedin=ALLBUT,impetusComment,impetusString,impetusKeyword`
   - Updated `intrinsic.lua` (lines 310, 322, 336): dynamic intrinsics use same exclusions
   - Prevents single-letter intrinsics (`t`, `x`, `y`, `z`) from highlighting inside keyword names (e.g., `*TRANSFORM_MESH_CYLINDRICAL`)
   
### Parameter Definition Alignment (`:clean -a`, `:clean -s`)
   - Replaced separate `format_parameter_definition_lines()` and `align_parameter_comments()` with unified `align_parameter_definitions_comprehensive()` function in `commands.lua`
   - **Three-stage alignment:**
     1. **Equals signs**: Parameters flush-left (no indent padding), right-padded with spaces to align `=` signs
     2. **Values**: Left-aligned after ` = `, right-padded if followed by comment/description  
     3. **Comments/Descriptions**: Aligned to a single column (comments at +2 spaces after longest value)
   - Integrates comments (`#`), descriptions with quotes (`", "desc"`), and parameter names in proper alignment
   - Integrated into both `align_parameter_blocks_in_buffer()` and `simple_beautify_buffer()`
   - Example:
     ```
     Before:
     H = 0.005 # ring height
     R0 = 0.010 # inner radius
     R1 = 0.015 # outer radius
     dR = 0.0005 # radial distortion
     
     After:
     H   = 0.005       # ring height
     R0  = 0.010       # inner radius
     R1  = 0.015       # outer radius
     dR  = 0.0005      # radial distortion
     ```
     Note: Parameter names start at column 0 (flush-left), spaces added to the right to align all `=` signs

### Bidirectional Reference Tracking with Unopened File Support
   - **New function**: `build_reverse_include_map()` (analysis.lua:2009) builds a reverse mapping of include relationships
     - Traverses all open impetus buffers recursively
     - Records which files include which files
     - Supports nested includes (A -> B -> C scenarios)
   - **New function**: `scan_unopened_file_refs()` (analysis.lua:1875) scans unopened files on disk
     - Returns full reference location data (row, col, keyword, line, file) without loading the file into a buffer
     - Recognizes all reference types (*SET_*, *GEOMETRY_SEED_NODE, fcn/crv calls, table references)
   - **Enhanced function**: `object_references()` (analysis.lua:2050) now includes four reference sources:
     1. Current buffer
     2. Included files (loaded buffers)
     3. Other open buffers
     4. **NEW**: Files that include current file (using reverse include map + unopened file scanning)
   - **User experience**: When pressing `gr` on an object ID in an included file:
     - Shows references from the main file that includes it
     - Shows references from unopened include files (without loading them)
     - Displays complete reference context (line content, keyword, filename)
   - Enables workflows like: edit include_b.key, press `gr` on node 10, see it's referenced in test_main.key at SET_FACE

---

## Common Development Tasks

### Add a new user command
1. Implement the handler in `lua/impetus/commands.lua` (or a new module).
2. Register in `init.lua`:
   ```lua
   vim.api.nvim_create_user_command("ImpetusNewCommand", function(args)
     require("impetus.commands").new_command_handler(args)
   end, { desc = "Description" })
   ```

### Add a new lint check
1. Add a function (e.g., `check_my_rule`) in `lua/impetus/lint.lua`.
2. Call it from `M.lint_buffer()` at the appropriate point.
3. Use `vim.diagnostic.set()` to report issues with the correct severity and namespace.

### Modify or extend the schema
- If schema comes from `commands.help`, parse/re-export and update `data/keywords.json`.
- If schema is hardcoded (enums, unit systems), update the table in `lint.lua` and `actions.lua` (watch for duplicates).

### Add a new completion source
Implement as a module in `lua/impetus/` and either:
- Hook into the omnifunc in `complete.lua`, or
- Register as a blink.cmp source (see `blink_source.lua` for the interface).

### Test a change
1. Open a test `.key` file in Neovim (or create one).
2. Verify the feature works (completion, linting, commands, etc.).
3. Check `impetus_nvim.log` for any errors or unexpected log lines.
4. Reload with `:ImpetusReload` or restart Neovim.

---

## Documentation Files

- **README.md** — Quick overview, features, and install instructions.
- **USER_MANUAL.md** — Comprehensive user guide: keyboard shortcuts, commands, workflows, configuration.
- **TECHNICAL_REPORT.md** — In-depth technical documentation of all engineering modifications, trade-offs, and performance analysis.

---

## Conventions & Practices

### Module structure
Each module exports a table `M` with public functions. Private functions are local and prefixed with underscore by convention (e.g., `local function _helper()`).

### Naming
- `M.` prefix for public functions.
- `_func_name` for private helpers.
- `local ns = vim.api.nvim_create_namespace(...)` for diagnostic/highlight namespaces (use plugin name in namespace).

### Error handling
- Use `pcall()` for optional dependencies (e.g., blink.cmp).
- Return `nil` or empty results for missing files; don't error unless truly broken.
- Log errors to `impetus_nvim.log` via `require("impetus.log").warn()` / `.error()`.

### Performance
- Cache file analysis by mtime (see `analysis.lua:file_mtime()`).
- Avoid O(n²) loops over large files; prefer indexed lookups.
- Use `vim.schedule_wrap()` for async operations if needed (though most operations are sync-on-demand).

### Testing
No automated test suite exists. Test manually by:
1. Opening `.key` files in Neovim.
2. Triggering commands and features.
3. Verifying output in the editor and logs.
4. Check edge cases (empty files, malformed keywords, cross-file includes).

---

## Useful Neovim API Patterns Used

- **`vim.api.nvim_get_current_buf()` / `nvim_buf_get_lines()` / `nvim_buf_set_lines()`** — Buffer manipulation.
- **`vim.api.nvim_set_extmark()` / `nvim_buf_clear_namespace()`** — Highlights and diagnostics.
- **`vim.diagnostic.set()`** — Report lint issues.
- **`vim.api.nvim_create_user_command()` / `nvim_buf_set_keymap()`** — Commands and keybindings.
- **`vim.fn.getpos()`, `vim.fn.col()`, `vim.fn.line()`** — Cursor/line utilities.
- **`vim.loop.fs_stat()`** — File stat for mtime checks.
- **`vim.lsp` / `vim.snippet` (Neovim 0.10+)** — LSP semantics and snippet expansion.

---

## Git Workflow

The repo is a standard Neovim plugin. Commits document:
- Feature additions (new lint checks, commands, etc.).
- Bug fixes with root cause and test case.
- Performance improvements with metrics.
- Documentation updates.

TECHNICAL_REPORT.md is the canonical record of significant modifications. Use it to understand the "why" behind design choices.

---

## Known Limitations & Future Work

See TECHNICAL_REPORT.md section 19 for known limitations and optimization opportunities:
- Hardcoded enum tables should be deduplicated or auto-generated.
- Large file performance could be improved via incremental analysis.
- Some checks are heuristic-based (e.g., `is_id_like`) and may have false positives on edge cases.
