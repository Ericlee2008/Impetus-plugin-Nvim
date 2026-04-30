# impetus.nvim

Neovim plugin scaffold for Impetus keyword authoring, based on `commands.help`.

## Features (v0)

- Filetype detection for `*.key`, `*.k`.

- Custom dark, high-contrast Impetus highlight palette (image-style magenta/cyan/green/red accents)

- Syntax highlighting for keywords, directives, parameters, repeat vars

- Parse `commands.help` into an in-memory keyword database

- Bundled starter database at `data/keywords.json` (generated from your current `commands.help`)


- `omnifunc` completion:
  
  - keyword completion (`*...`)
  - parameter completion (`%...`)
  - per-keyword parameter hints
  - context-aware object ID completion (e.g. `typeid` can suggest existing part IDs in current file)

- `blink.cmp` source `impetus.blink_source`:
  
  - keyword completion can expand into a full template block
  - inserts `"Optional title"`, `#` parameter row(s), and blank input row(s)
  - template insertion uses snippet placeholders so `Tab` jumps field-to-field
  - for Impetus buffers: `j/k` select menu item, `<Space>` accept when menu is visible

- Persistent field workflow:
  
  - `tab_field_jump = true` keeps `<Tab>` field-jump available even after snippet session ends
  - empty parameter fields are highlighted for easier revisit/editing

- Hover docs on `K`:
  
  - keyword signature
  - parameter description (from `commands.help`)

- Basic lint:
  
  - unknown keyword warning
  - first data row field-count hint
  - `~if/~else_if/~else/~end_if` balance checks
  - `~repeat/~end_repeat` balance checks
  - `~convert_from_/~end_convert` balance checks
  - warn on parameter references without in-file definitions

- Keyword folding by `*KEYWORD` blocks

- Outline and navigation helpers for keywords/parameters

- Export parsed database to JSON

- Export snippet templates to VSCode snippet JSON

## Install

Use as local plugin with your preferred manager.

### lazy.nvim

```lua
{
  "Ericlee2008/Impetus-plugin-Nvim",
  lazy = false,
  config = function()
    require("impetus").setup({
      lint_on_save = true,
    })
  end,
}
```

> **Note:** Using `lazy = false` is recommended because this plugin provides filetype detection (`ftdetect/`), syntax highlighting, and buffer-local keymaps that must be available before the buffer is opened. Delayed loading (`ft` or `event`) can cause filetype detection to fail on files opened from the command line (`nvim file.key`).

## Commands

- `:ImpetusLoadHelp /path/to/commands.help`
- `:ImpetusReload`
- `:ImpetusLint`
- `:ImpetusOutline`
- `:ImpetusParamDef [name]`
- `:ImpetusParamRefs [name]`
- `:ImpetusObjects`
- `:ImpetusPreviewGeometry`
- `:ImpetusExportJson /path/to/keywords.json`
- `:ImpetusExportSnippets /path/to/impetus.code-snippets`

## Workflow

1. Open any `*.key` file.
2. Trigger completion via `<C-x><C-o>` (omnifunc) or your completion framework.
3. Put cursor on keyword/parameter and press `K`.
4. Run `:ImpetusPreviewGeometry` to open a simple model viewer for the current block.
5. Run `:ImpetusLint` to inspect current buffer.

## Notes

- Parser is tolerant to numbered lines in `commands.help` (`1. *KEYWORD`).
- Non-ASCII symbols in source docs are preserved as-is.
- Load order: `help_file` -> cache -> bundled `data/keywords.json`.
- This is a strong base layer; semantic checks for `~if`, `~repeat`, unit conversion can be added in the next phase.
