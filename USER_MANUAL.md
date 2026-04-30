# impetus.nvim — Comprehensive User Manual

**Version:** Current (post-v0)  
**Target:** LS-DYNA / Impetus input file authoring in Neovim  
**Filetypes:** `impetus`  
**Default Local Leader:** `,`

---

## Table of Contents

1. [Overview](#1-overview)
2. [Installation](#2-installation)
3. [Filetype Detection](#3-filetype-detection)
4. [Keyboard Shortcuts](#4-keyboard-shortcuts)
5. [Commands Reference](#5-commands-reference)
6. [Lint (`:Ccheck`) — Model Validation](#6-lint-ccheck--model-validation)
7. [Parameter System](#7-parameter-system)
8. [Clean Commands](#8-clean-commands)
9. [Replace Commands (`:re`)](#9-replace-commands-re)
10. [Navigation (`gd` / `gr`)](#10-navigation-gd--gr)
11. [Completion System](#11-completion-system)
12. [Folding](#12-folding)
13. [Help Pane & Side Help](#13-help-pane--side-help)
14. [Info Pane](#14-info-pane)
15. [Object Graph Commands](#15-object-graph-commands)
16. [Intrinsic Functions (`gh`)](#16-intrinsic-functions-gh)
17. [Operation Log File](#17-operation-log-file)
18. [Cross-File Parameter Resolution](#18-cross-file-parameter-resolution)
19. [Configuration Options](#19-configuration-options)
20. [Physics Sanity Checks](#20-physics-sanity-checks)
21. [Special Semantics](#21-special-semantics)
22. [Recommended Workflow](#22-recommended-workflow)

---

## 1. Overview

`impetus.nvim` is a Neovim plugin that turns your editor into an IDE for Impetus / LS-DYNA keyword input files (`*.k`, `*.key`). It provides:

- **Syntax highlighting** with a custom dark, high-contrast palette (magenta/cyan/green/red accents)
- **Intelligent completion** for keywords, parameters, object IDs, and enumerated options
- **Real-time linting** with three severity tiers: Error, Warning, and Suspicion
- **Parameter algebra** — define `%params` and substitute or evaluate them inline
- **Cross-file awareness** — recursively resolves `*INCLUDE` files for parameter and object references
- **Navigation** — jump to definitions, find references, browse object registries
- **Folding** — collapse keyword blocks and control directives (`~if`, `~repeat`, `~convert`)
- **Side help pane** — live parameter documentation from `commands.help`
- **Operation logging** — every structural change is recorded to `impetus_nvim.log`

---

## 2. Installation

### lazy.nvim

```lua
{
  dir = "E:/AI/codex/case1/impetus.nvim",
  config = function()
    require("impetus").setup({
      help_file = "E:/AI/codex/case1/commands.help",
      auto_load = true,
      lint_on_save = true,
    })
  end,
}
```

The plugin loads the keyword database in this priority:

1. `help_file` (if provided and readable)
2. Cached database (`cache_file` or auto-detected)
3. Bundled `data/keywords.json`

---

## 3. Filetype Detection

The plugin automatically sets `filetype=impetus` for:

- `*.k`
- `*.key`
- `commands.help`

Buffers manually set to `impetus` also receive all plugin behaviors.

---

## 4. Keyboard Shortcuts

All shortcuts are **buffer-local** and use `<localleader>` (default `,`). They do not pollute other filetypes.

### 4.1 Core Editing

| Shortcut    | Mode          | Description                                                 |
| ----------- | ------------- | ----------------------------------------------------------- |
| `,c`        | Normal        | Toggle comment/uncomment current keyword block              |
| `dk`        | Normal        | Delete (cut) current keyword or control block to register   |
| `,y`        | Normal        | Yank current block to register                              |
| `,j`        | Normal        | Move current keyword block down                             |
| `,k`        | Normal        | Move current keyword block up                               |
| `<Tab>`     | Insert/Normal | Jump to next parameter field (when `tab_field_jump = true`) |
| `,I`        | Normal        | Insert keyword template at cursor                           |
| `,Q`        | Normal        | Close popup / quickfix                                      |
| `gh`        | Normal        | Show intrinsic function/variable hover docs                 |
| `<C-Space>` | Insert        | Trigger Impetus omnifunc completion                         |
| `<Space>`   | Insert        | Accept completion item (when menu visible)                  |

### 4.2 Navigation

| Shortcut | Mode   | Description                                                       |
| -------- | ------ | ----------------------------------------------------------------- |
| `,n`     | Normal | Jump to next keyword                                              |
| `,N`     | Normal | Jump to previous keyword                                          |
| `gd`     | Normal | Jump to definition (parameter, object ID, or `fcn(id)`/`crv(id)`) |
| `gr`     | Normal | List references (popup or quickfix; supports `fcn(id)`/`crv(id)`) |
| `%`      | Normal | Match jump (`~if`/`~end_if`, brackets)                            |
| `,m`     | Normal | Jump to matching control block                                    |
| `,b`     | Normal | Check unmatched control blocks                                    |
| `,o`     | Normal | Open `*INCLUDE` / `*SCRIPT_PYTHON` file under cursor (left split) |
| `,O`     | Normal | Open current file in Impetus GUI                                  |

### 4.3 Folding

| Shortcut | Description                                                 |
| -------- | ----------------------------------------------------------- |
| `,f`     | Toggle fold all keyword blocks (auto)                       |
| `,t`     | Toggle fold at current keyword block                        |
| `,F`     | Toggle fold all control blocks (`~if`/`~repeat`/`~convert`) |
| `,T`     | Toggle fold at current control block                        |
| `,z`     | Toggle fold all keywords + control blocks                   |

### 4.4 Help & Info

| Shortcut | Description                                               |
| -------- | --------------------------------------------------------- |
| `,h`     | Toggle right help pane (keyword signature + descriptions) |
| `,,`     | Trigger reference / option completion popup               |
| `,R`     | Same as `,,`                                              |
| `,i`     | Toggle info pane (model statistics tree)                  |
| `,r`     | Reload `commands.help` database                           |
| `,u`     | Open quick help cheat sheet popup                         |
| `K`      | Show docs for keyword or parameter under cursor           |
| `,q`     | Force quit current window                                 |

### 4.5 Blink.cmp Menu Keys (when `blink_menu_keys = true`)

| Key               | Behavior                    |
| ----------------- | --------------------------- |
| `j` / `k`         | Select next / previous item |
| `<Down>` / `<Up>` | Same as `j` / `k`           |
| `<Space>`         | Accept selected item        |

---

## 5. Commands Reference

### 5.1 Full Commands

| Command                    | Arguments   | Description                                                    |
| -------------------------- | ----------- | -------------------------------------------------------------- |
| `:ImpetusLoadHelp`         | `<path>`    | Load keyword database from `commands.help`                     |
| `:ImpetusReload`           | —           | Reload the currently cached database                           |
| `:ImpetusLint`             | —           | Run all lint checks on current buffer                          |
| `:ImpetusOutline`          | —           | Open quickfix with all keywords                                |
| `:ImpetusParamDef`         | `[name]`    | Jump to parameter definition (default: cursor)                 |
| `:ImpetusParamRefs`        | `[name]`    | List references for parameter (default: cursor)                |
| `:ImpetusObjects`          | —           | Open quickfix with object ID registry                          |
| `:ImpetusInfo`             | —           | Toggle info pane                                               |
| `:ImpetusHelpToggle`       | —           | Toggle right help pane                                         |
| `:ImpetusHelpOpen`         | —           | Open help pane                                                 |
| `:ImpetusHelpClose`        | —           | Close help pane                                                |
| `:ImpetusCheatSheet`       | —           | Open quick help popup                                          |
| `:ImpetusRefresh`          | —           | Full plugin + database refresh (`dev_hot_reload`)              |
| `:ImpetusUpdate`           | —           | Force refresh of index, lint, and ref marks for current buffer |
| `:ImpetusClean`            | `[args]`    | Clean command (see §8)                                         |
| `:ImpetusClear`            | `[args]`    | Alias for `:ImpetusClean`                                      |
| `:ImpetusReplaceParams`    | `[-a｜-b]`   | Replace parameters with values (see §9)                        |
| `:ImpetusRefComplete`      | —           | Trigger reference/option completion                            |
| `:ImpetusOpenGUI`          | —           | Open file in Impetus GUI                                       |
| `:ImpetusCheckBlocks`      | —           | Check unmatched `~if`/`~repeat`/`~convert`                     |
| `:ImpetusFoldBounds`       | —           | Show fold boundary analysis                                    |
| `:ImpetusTryKeywordFold`   | —           | Try keyword fold on current block                              |
| `:ImpetusTryControlFold`   | —           | Try control fold on current block                              |
| `:ImpetusFoldDoctor`       | —           | Open fold diagnostic view                                      |
| `:ImpetusGraphInfo`        | —           | Open object/reference graph summary                            |
| `:ImpetusGraphRefs`        | `[type:id]` | Show inbound/outbound refs for object                          |
| `:ImpetusGraphDeleteCheck` | `[type:id]` | Check if object can be deleted safely                          |
| `:ImpetusExportJson`       | `<path>`    | Export keyword DB to JSON                                      |
| `:ImpetusExportSnippets`   | `<path>`    | Export snippet templates to VSCode JSON                        |
| `:ImpetusHighlightProbe`   | —           | Arm syntax-highlight probe (debug)                             |

### 5.2 Short Aliases (C* Family & Short Forms)

| Alias                       | Maps To                    | Description                   |
| --------------------------- | -------------------------- | ----------------------------- |
| `:Ccheck` / `:Cc` / `:Chk`  | `:ImpetusLint`             | Run lint                      |
| `:Chelp`                    | `:ImpetusCheatSheet`       | Quick help popup              |
| `:Ch`                       | `:ImpetusHelpToggle`       | Toggle help pane              |
| `:Cinfo` / `:Ci`            | `:ImpetusInfo`             | Toggle info pane              |
| `:Cregistry` / `:Cr`        | `:ImpetusObjects`          | Object registry               |
| `:Crefresh` / `:CR`         | `:ImpetusRefresh`          | Full refresh                  |
| `:Update`                   | `:ImpetusUpdate`           | Force buffer analysis refresh |
| `:Creload` / `:Crl`         | `:ImpetusReload`           | Reload database               |
| `:Cgoto` / `:Cg`            | `:ImpetusParamDef`         | Goto definition               |
| `:Cfind` / `:Cw`            | `:ImpetusParamRefs`        | Find references               |
| `:Cref` / `:Cf`             | `:ImpetusRefComplete`      | Ref completion                |
| `:Cgraph`                   | `:ImpetusGraphInfo`        | Graph summary                 |
| `:Cgr`                      | `:ImpetusGraphRefs`        | Graph refs                    |
| `:Cgdel`                    | `:ImpetusGraphDeleteCheck` | Delete safety check           |
| `:Cblock`                   | `:ImpetusCheckBlocks`      | Control block check           |
| `:Cfoldbounds`              | `:ImpetusFoldBounds`       | Fold analysis                 |
| `:Ctrykwfold`               | `:ImpetusTryKeywordFold`   | Try keyword fold              |
| `:Ctryctlfold`              | `:ImpetusTryControlFold`   | Try control fold              |
| `:Cfolddbg`                 | `:ImpetusFoldDoctor`       | Fold doctor                   |
| `:Cgui` / `:Co` / `:Copen`  | `:ImpetusOpenGUI`          | Open in GUI                   |
| `:Re`                       | `:ImpetusReplaceParams`    | Replace params                |
| `:Clean` / `:Clear` / `:Cl` | `:ImpetusClean`            | Clean                         |
| `:Info` / `:Inf`            | `:ImpetusInfo`             | Info pane                     |
| `:Help` / `:Hp`             | `:ImpetusCheatSheet`       | Cheat sheet                   |
| `:Gui`                      | `:ImpetusOpenGUI`          | Open GUI                      |
| `:Obj`                      | `:ImpetusObjects`          | Object registry               |
| `:Refs`                     | `:ImpetusParamRefs`        | References                    |
| `:Def`                      | `:ImpetusParamDef`         | Definition                    |
| `:Rl`                       | `:ImpetusReload`           | Reload DB                     |

---

## 6. Lint (`:Ccheck`) — Model Validation

`:Ccheck` (or `:Cc`, `:Chk`) runs **11 diagnostic checks** across three severity tiers. Results appear as Neovim diagnostics (virtual text + signs) and are stored in the `impetus-lint` namespace.

### 6.1 Severity Tiers

| Tier                | Sign | Meaning                                                                         |
| ------------------- | ---- | ------------------------------------------------------------------------------- |
| **Error** (`E`)     | `E`  | Structural errors, undefined references, duplicate IDs, missing required fields |
| **Warning** (`W`)   | `W`  | Unknown keywords, empty blocks, unused parameters, field count mismatches       |
| **Suspicion** (`?`) | `?`  | Physical values outside common-sense ranges (density, modulus, scale, velocity) |

### 6.2 Check Descriptions

| #   | Check                   | Severity        | Description                                                                                            |
| --- | ----------------------- | --------------- | ------------------------------------------------------------------------------------------------------ |
| 1   | **Control blocks**      | Error           | Unmatched `~if`/`~else_if`/`~else`/`~end_if`, `~repeat`/`~end_repeat`, `~convert_from_`/`~end_convert` |
| 2   | **Unknown keywords**    | Warning         | `*KEYWORD` not found in `commands.help` database                                                       |
| 3   | **Field counts**        | Error           | First data row has more comma-separated fields than the signature row expects                          |
| 4   | **Parameter refs**      | Error           | `%param` referenced but never defined (cross-file aware)                                               |
| 5   | **Unused params**       | Warning         | `%param` defined but never referenced (cross-file aware)                                               |
| 6   | **Duplicate IDs**       | Error           | Same object ID (part, material, etc.) defined more than once in the same file                          |
| 7   | **Missing includes**    | Error           | `*INCLUDE` file path does not exist on disk                                                            |
| 8   | **Empty blocks**        | Warning         | Keyword block has no data rows (except `*END`, `*TITLE`)                                               |
| 9   | **Object refs**         | Error / Warning | Reference to undefined object ID; downgraded to Warning if `*INCLUDE` is present                       |
| 10  | **Required fields**     | Error           | Mandatory fields are empty or `-` (per-keyword logic, see below)                                       |
| 11  | **Enum values**         | Error           | Field value does not match accepted options from `commands.help`                                       |
| 12  | **Physics sanity**      | Suspicion       | Density, Young's modulus, length, velocity, mass outside typical ranges for detected unit system       |
| 13  | **Missing unit system** | Warning         | File contains `*MAT_*` / `*PART` / `*LOAD` but no `*UNIT_SYSTEM`                                       |

### 6.3 Required-Field Logic

- `*PARAMETER` / `*PARAMETER_DEFAULT`: First data row must contain `%name = expression`
- `*FUNCTION`: `fid` required; second data row (expression) required
- `*MAT_*`: `mid` / `id` required; all other fields lenient
- `*PART`: `pid` required; `mid` required **unless** the `pid` is referenced by any `*GEOMETRY_PART`
- `*OUTPUT`: First two fields (`Δt_imp`, `Δt_ascii`) required
- `*PARTICLE_DOMAIN`: `n_p` required unless `*GENERATE_PARTICLE_DISTRIBUTION` exists
- Generic keywords: Fields marked "optional", having a `default`, or with explicit `options:` are not required

### 6.4 Optional ID Row Detection

Some keywords have an optional single-field ID row (e.g., `coid` or `bcid`) followed by a multi-field data row. If the first data value is non-numeric and the first schema parameter looks like an ID (pure number or ends in `id`/`ID`), the linter treats the first data row as the **second** schema row. This prevents false field-count and enum errors for omitted ID rows.

Examples: `*INCLUDE` (first param is `filename`, not an ID) is **not** shifted; `*BC_MOTION` (first param `bcid`) **is** shifted when omitted.

### 6.5 Clearing Diagnostics

Run `:clean` or `:clear` (no arguments) to clear all lint diagnostics and pair markers.

---

## 7. Parameter System

### 7.1 Definitions

Parameters are defined in `*PARAMETER` or `*PARAMETER_DEFAULT` blocks:

```
*PARAMETER
%L = 100.0
%thickness = 2.5
%area = %L * %thickness
```

- Parameter names are case-insensitive
- Values can be numeric literals, expressions, or references to other parameters
- `*PARAMETER` overrides `*PARAMETER_DEFAULT`

### 7.2 References

Use parameters anywhere in data rows:

```
*PART
1, 1, %thickness
```

Bracket form supports inline math:

```
*PART
1, 1, [%L / 2]
```

### 7.3 Cross-File Resolution

If the current file contains `*INCLUDE` references, parameters defined in included files are **automatically available** in the parent file. The linter's "undefined parameter" and "unused parameter" checks operate across the entire include tree.

---

## 8. Clean Commands

The `:clean` / `:clear` family removes noise and reformats the buffer.

### 8.1 `:clean` (no args)

- Clears directive pair markers (`pairX` virtual text)
- Resets `impetus-lint` diagnostics
- Does **not** modify buffer content

### 8.2 `:clean -c` (warm clean)

Removes from the buffer:

- Blank lines inside and between keyword blocks
- Comment lines (`#` / `$`) inside blocks
- Comma-only placeholder lines (smart keep: preserved if the schema expects multi-field rows)

**Logged:** Every removed line is written to `impetus_nvim.log` with row number, reason, and original text.

### 8.3 `:clean -a` (full clean)

Runs `:clean -c` **plus**:

- **Advanced prune**: Removes unknown keyword blocks entirely, strips leading/trailing blank lines inside known blocks
- **Align parameters**: Formats `*PARAMETER` / `*PARAMETER_DEFAULT` blocks so `=` signs and trailing comments line up

After `:clean -a`, intrinsic syntax highlighting is reapplied.

---

## 9. Replace Commands (`:re`)

### 9.1 `:re`

Replaces all `%param` references with their defined values (plain text substitution). Does **not** evaluate arithmetic.

Example:

```
Before: 1, 1, %thickness
After : 1, 1, 2.5
```

### 9.2 `:re -a`

Replaces parameters **and** evaluates all numeric expressions, including bracket expressions.

Example:

```
Before: 1, 1, [%L / 2]
After : 1, 1, 50
```

The evaluator is a fast recursive-descent parser supporting `+ - * / ^ ( )` and scientific notation. It runs up to 4 simplify passes to resolve nested expressions.

### 9.3 `:re -b`

**Replace all** (including `*PARAMETER` / `*PARAMETER_DEFAULT` definition rows) **and evaluate** with **intrinsic math functions** support.

Supported functions: `sin`, `cos`, `tan`, `asin`, `atan`, `tanh`, `sinr`, `cosr`, `tanr`, `asinr`, `acosr`, `atanr`, `exp`, `ln`, `log`, `log10`, `sqrt`, `abs`, `sign`, `floor`, `ceil`, `round`, `mod`, `min`, `max`, `H` (Heaviside), `d` (Kronecker delta), `erf`. Constants: `pi`.

Angles for `sin`/`cos`/`tan` are in **degrees**; `sinr`/`cosr`/`tanr` use **radians**.

Example:

```
Before: r22 = sin(%angle)        (*PARAMETER definition)
After : r22 = 0.5                (definition itself is replaced)
```

**Key difference from `:re -a`:**

- `:re -a` skips `*PARAMETER` definition rows (only replaces references)
- `:re -b` also replaces and evaluates inside `*PARAMETER` blocks

**Auto-refresh:** After `:re -a` or `:re -b` makes changes, the plugin automatically refreshes the buffer index, lint diagnostics, and ref marks (green/blue underlines), since `nvim_buf_set_lines` does not trigger `TextChanged`.

**Logged:** Every changed line is written to `impetus_nvim.log` with row number, before, and after values.

---

## 10. Navigation (`gd` / `gr`)

### 10.1 `gd` — Goto Definition

Context-aware jump:

1. **On `%param`**: Jumps to the `*PARAMETER` definition line
2. **On `fcn(id)` / `crv(id)`**: If the parameter description mentions "function" or "curve", jumps to the matching `*FUNCTION` / `*CURVE` definition
3. **On object reference field** (e.g., `pid`, `mid`, `gid`, `tabid`): Jumps to the keyword block that defines that ID (e.g., `tabid` → `*TABLE`)
4. **On definition keyword** (e.g., `*PART` line): Notifies that you are already at the definition

If the target is in another file, it opens in a left-side navigation split.

### 10.2 `gr` — Find References

Lists all references to the item under cursor. Results are shown in a popup (if multiple) or jumped to directly (if exactly one). The popup shows:

- Line number and kind (`def` / `ref`)
- Source file (if cross-file)
- Keyword tag (e.g., `*PART`)

Use `<Space>` or `<CR>` to jump to the selected item; `q` or `<Esc>` to close.

---

## 11. Completion System

### 11.1 Omnifunc (`<C-x><C-o>`)

Triggered manually or via `<C-Space>` in insert mode. Provides:

- **Keyword completion**: Type `*` to see all keywords; selecting one can insert a full template block with title, parameter row, and blank data rows
- **Parameter completion**: Type `%` to see defined parameters
- **Object ID completion**: Context-aware suggestions (e.g., `typeid` suggests existing part IDs)
- **Option completion**: For fields with enumerated options in `commands.help`

### 11.2 Blink.cmp Integration

If `blink.cmp` is installed, the plugin provides a source `impetus_kw` that:

- Expands keyword completion into snippet templates
- Uses snippet placeholders so `<Tab>` jumps field-to-field
- Supports `j`/`k` navigation and `<Space>` acceptance (when `blink_menu_keys = true`)

### 11.3 Ref/Option Completion (`,,` / `,R`)

In normal or insert mode, `,,` opens a floating popup with context-aware candidates:

- If cursor is on an object-reference field (`pid`, `mid`, `gid`, etc.): lists all defined IDs of that type
- If cursor is on a field with known options: lists accepted option values
- If cursor is on `*UNIT_SYSTEM units`: lists all 14 valid unit system strings

Use `j`/`k` to navigate, `<Space>` / `<CR>` to accept, `q` / `<Esc>` to close.

---

## 12. Folding

Folding is based on `*KEYWORD` blocks and control directives. All folds start open (`foldlevel=99`).

| Action | Result                                      |
| ------ | ------------------------------------------- |
| `,f`   | Toggle all keyword folds closed / open      |
| `,t`   | Toggle fold at current keyword              |
| `,F`   | Toggle all control block folds              |
| `,T`   | Toggle fold at current control block        |
| `,z`   | Toggle everything                           |
| `,m`   | Jump between matching `~if`/`~end_if`, etc. |

The `%` key also jumps between matching directives (falls back to native bracket matching if not on a directive).

---

## 13. Help Pane & Side Help

### 13.1 Right Help Pane (`,h`)

Opens a fixed-width right-side window showing:

- The current keyword's signature rows
- Parameter descriptions from `commands.help`
- The parameter under the cursor is **highlighted** in the signature

The pane updates automatically as you move the cursor between keyword blocks.

### 13.2 Quick Help Popup (`,u` / `:Chelp`)

A centered floating window with all shortcuts and commands. Press `q`, `<Esc>`, or `<CR>` to close.

---

## 14. Info Pane

Toggle with `,i` or `:Cinfo`. Shows a tree view of:

- File statistics (keyword count, parameter count, object counts)
- Keyword list with line numbers
- Object registry summary

---

## 15. Object Graph Commands

### 15.1 `:Cgraph` — Graph Summary

Opens a first-pass summary of all objects and their reference relationships in the current buffer.

### 15.2 `:Cgr` — Graph References

Shows inbound and outbound references for the object under cursor (or accepts `type:id` as argument).

### 15.3 `:Cgdel` — Delete Safety Check

Analyzes whether the object under cursor can be safely deleted without breaking references from other objects.

---

## 16. Intrinsic Functions (`gh`)

`intrinsic.k` functions and variables are automatically syntax-highlighted (green for functions, yellow for variables). Press `gh` on any intrinsic token to see:

- Function signature
- Return type
- Description

---

## 17. Operation Log File

All mutating operations are appended to **`impetus_nvim.log`** in the **current working directory** (`vim.fn.getcwd()`).

### 17.1 Logged Operations

| Command               | Logged Details                                                                       |
| --------------------- | ------------------------------------------------------------------------------------ |
| `:clean -c`           | Removed line count, each line's row, reason, and text                                |
| `:clean -a`           | Warm + advanced removed counts, aligned parameter count, each line's row/reason/text |
| `:re`                 | Changed line count, before/after for each modified line                              |
| `:re -a`              | Same as `:re`, flagged with `mode=re -a`                                             |
| `:re -b`              | Same as `:re`, flagged with `mode=re -b`                                             |
| `,,` (ref completion) | Selected value, target file, row, parameter name                                     |

### 17.2 Log Format

```
=== clean -a 2026-04-20 14:30:00 ===
File: E:\models\crash.k
[summary] removed=42 (warm=30 adv=12)  PARAMETER aligned=5
[warm clean]
  L15    blank         
  L23    comment       # old note
[advanced clean]
  L45    unknown-block *UNKNOWN_KEY (3 lines)

=== re -a 2026-04-20 14:32:00 ===
File: E:\models\crash.k
[summary] changed=5 apply_arith=true
  L10    before: 1, 1, [%L / 2]
         after : 1, 1, 50
```

The log is **append-only** and never truncated automatically.

---

## 18. Cross-File Parameter Resolution

`build_cross_file_param_index()` recursively scans:

1. All `*INCLUDE` files reachable from the current buffer
2. All currently open buffers with `filetype=impetus`

It merges:

- **Definitions** (`*PARAMETER`, `*PARAMETER_DEFAULT`) from all sources
- **References** (`%param` usages) from all sources

This means:

- A parameter defined in an included file is **not** flagged as "undefined" in the parent
- A parameter used only in an included file is **not** flagged as "unused" in the parent
- Object references across includes are downgraded from **Error** to **Warning** (since the object may exist in the included file)

---

## 19. Configuration Options

Set these in your `setup({...})` call:

| Option                    | Default       | Description                                   |
| ------------------------- | ------------- | --------------------------------------------- |
| `help_file`               | `nil`         | Path to `commands.help`                       |
| `auto_load`               | `true`        | Auto-load database on startup                 |
| `cache_file`              | `nil`         | Custom cache path                             |
| `lint_on_save`            | `true`        | Run `:Ccheck` on `:w`                         |
| `filetypes`               | `{"impetus"}` | Filetypes to attach                           |
| `blink_retrigger_on_star` | `true`        | Retrigger blink on `*` in insert mode         |
| `blink_menu_keys`         | `false`       | Enable `j`/`k`/`<Space>` in blink menu        |
| `tab_field_jump`          | `true`        | `<Tab>` jumps fields instead of inserting tab |
| `side_help_track`         | `true`        | Enable right help pane tracking               |
| `side_help_width`         | `68`          | Help pane width                               |
| `dev_hot_reload`          | `true`        | Auto-reload plugin/help on `FocusGained`      |
| `dev_mode`                | `false`       | Enable `:Cdbg` and `:Cdoctor` commands        |

---

## 20. Physics Sanity Checks

When a `*UNIT_SYSTEM` is detected, `:Ccheck` validates physical quantities against common-sense ranges for that unit system.

### 20.1 Supported Unit Systems (14 valid forms)

| Canonical | Aliases              |
| --------- | -------------------- |
| `SI`      | `SI`                 |
| `MMTONS`  | `MMTONS`, `MM/TON/S` |
| `CMGUS`   | `CMGUS`, `CM/G/US`   |
| `IPS`     | `IPS`                |
| `MMKGMS`  | `MMKGMS`, `MM/KG/MS` |
| `CMGS`    | `CMGS`, `CM/G/S`     |
| `MMGMS`   | `MMGMS`, `MM/G/MS`   |
| `MMMGMS`  | `MMMGMS`, `MM/MG/MS` |

### 20.2 Checked Quantities

| Quantity              | Fields Checked                     | Typical Steel Reference |
| --------------------- | ---------------------------------- | ----------------------- |
| Density (`rho`)       | `rho`, `density`                   | ~7850 kg/m³ (SI)        |
| Young's modulus (`e`) | `e`, `young`, `youngs`             | ~210 GPa (SI)           |
| Length / coordinates  | `x`, `y`, `z`, `x_*`, `y_*`, `z_*` | —                       |
| Velocity              | `v`, `vx`, `vy`, `vz`, `velocity*` | —                       |
| Mass                  | `m`, `mass`                        | —                       |

---

## 21. Special Semantics

### 21.1 Zero-ID Semantics (`0`)

The value `0` means "undefined / unset" for damage, thermal, and EOS references. The plugin treats `0` as a **non-reference**:

- `:Ccheck` does **not** report "undefined object" for `did=0`, `thpid=0`, `eosid=0`
- `gd` / `gr` on `0` does nothing
- Object tracking ignores `id == "0"`

### 21.2 `pid_offset` / `mid_offset` Disconnected

Parameters named `pid_offset`, `mid_offset`, etc. are **not** treated as object references. Only exact matches (`pid`, `mid`, `fid`, `gid`, `did`, `thpid`, `eosid`, `tabid`) and their `_N` suffixes (`pid_1`, `mid_2`, `tabid_m`, etc.) are classified as references.

- `tabid` references resolve to `*TABLE` definitions (first field `coid`).
- `sph` and `dp` (discrete particle) IDs are tracked for `*PARTICLE_SPH` / `*PARTICLE_HE` / `*PARTICLE_AIR` / `*PARTICLE_SOIL`.

### 21.3 `*INCLUDE` Path Format

Missing include diagnostics use normalized absolute paths (`C:/path/to/file.k`) instead of raw mixed-slash strings.

---

## 22. Recommended Workflow

1. **Setup**: Open a `*.k` file. The plugin auto-detects filetype and loads the keyword database.
2. **Authoring**: Type `*` to trigger keyword completion. Use `<Tab>` to jump fields. Use `,,` for object ID / option completion.
3. **Navigation**: Use `gd` to jump to definitions, `gr` to find references. Use `,o` to open included files.
4. **Structuring**: Use `,f` / `,F` to fold blocks. Use `,j` / `,k` to reorder blocks. Use `,c` to comment out experimental blocks.
5. **Parameters**: Define reusable values in `*PARAMETER`. Use `:re` for plain substitution, `:re -a` to inline and evaluate numerically, or `:re -b` to also evaluate inside `*PARAMETER` blocks with intrinsic functions (`sin`, `H()`, etc.).
6. **Validation**: Run `:Cc` periodically. Fix Errors first, then Warnings, then review Suspicions.
7. **Cleanup**: Before exporting, run `:clean -a` to strip comments/blank lines, remove unknown blocks, and align parameter definitions.
8. **Logging**: Check `impetus_nvim.log` in your project root for a full audit trail of all replacements and cleanups.
