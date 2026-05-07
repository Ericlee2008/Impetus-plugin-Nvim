---
name: impetus-help-sync
description: Keep the impetus.nvim user-facing command and shortcut documentation synchronized. Use when editing this Impetus Neovim plugin and adding, removing, renaming, or changing any keymap, localleader shortcut, command, command alias, command-line shortcut, help popup entry, or related user-visible workflow; update the `,u` mini help popup and Markdown docs in the same change.
---

# Impetus Help Sync

## Workflow

When changing any user-visible shortcut or command in the `impetus.nvim` project, update the code and documentation together.

1. Identify the user-facing surface changed:
   - Buffer keymaps in `lua/impetus/init.lua`, especially `<localleader>` mappings.
   - User commands and aliases in `lua/impetus/commands.lua`.
   - Command-line shortcuts handled in `commands.lua`, such as short `:re`, `:clean`, `:info`, `:help`, `:gui`, or similar forms.
   - Action-backed shortcuts in `lua/impetus/actions.lua`.

2. Update the mini help opened by `,u`:
   - Locate `show_cheatsheet_popup()` in `lua/impetus/commands.lua`.
   - Add, remove, or revise the relevant line in the same section as similar shortcuts or commands.
   - Keep labels concise enough for the popup width.
   - Preserve the existing tone and formatting of the popup.

3. Update Markdown documentation:
   - Prefer `USER_MANUAL.md` for user-facing shortcuts and command reference.
   - Update `README.md` when the feature belongs in the short public overview or command list.
   - Update `TECHNICAL_REPORT.md` only when the change is a notable implementation/design change, not for every small keymap.

4. Keep docs and implementation names exact:
   - Match key notation exactly, for example `,H`, `<localleader>H`, `:ImpetusPreviewGeometry`, or `:Cgeo`.
   - Mention fallback behavior or platform limitations when the command opens external programs or browser pages.
   - If a shortcut has both normal-mode and insert-mode mappings, document both only when users need to know both.

5. Verify before finishing:
   - Search for stale mentions of the old key or command with `rg`.
   - Run a lightweight Neovim load check when Lua code changed.
   - In the final response, explicitly say that the mini help and Markdown docs were updated, or state why no doc update was needed.

## Guardrails

- Do not add unrelated documentation rewrites while updating one shortcut or command.
- Do not document internal helper functions unless they are exposed through a keymap, user command, alias, popup, or user workflow.
- Do not leave a new shortcut or command undocumented unless the user explicitly requests an internal-only change.
