---
name: impetus-help-sync
description: Keep the impetus.nvim user-facing help and Markdown documentation synchronized. Use when editing this Impetus Neovim plugin and adding new features, fixing user-visible bugs, or adding, removing, renaming, or changing any keymap, localleader shortcut, command, command alias, command-line shortcut, help popup entry, syntax/highlight behavior, lint behavior, navigation behavior, or related user-visible workflow; update the `,u` mini help popup when shortcuts/commands change and update Markdown docs in the same change.
---

# Impetus Help Sync

## Workflow

When changing any user-visible behavior in the `impetus.nvim` project, update the code and documentation together. This includes new features, user-visible bug fixes, shortcut or command changes, syntax/highlight changes, lint behavior changes, navigation behavior changes, and external tool/browser workflows.

1. Identify the user-facing surface changed:
   - Buffer keymaps in `lua/impetus/init.lua`, especially `<localleader>` mappings.
   - User commands and aliases in `lua/impetus/commands.lua`.
   - Command-line shortcuts handled in `commands.lua`, such as short `:re`, `:clean`, `:info`, `:help`, `:gui`, or similar forms.
   - Action-backed shortcuts in `lua/impetus/actions.lua`.
   - Syntax and highlight behavior in `syntax/impetus.vim`, `lua/impetus/intrinsic.lua`, or `lua/impetus/highlight.lua`.
   - Lint, analysis, completion, include handling, parameter handling, navigation, or preview behavior that users can observe.

2. Update the mini help opened by `,u`:
   - Locate `show_cheatsheet_popup()` in `lua/impetus/commands.lua`.
   - Add, remove, or revise the relevant line in the same section as similar shortcuts or commands.
   - Keep labels concise enough for the popup width.
   - Preserve the existing tone and formatting of the popup.
   - Skip this step only when the change does not affect any shortcut, command, alias, or help-popup workflow.

3. Update Markdown documentation:
   - Prefer `USER_MANUAL.md` for user-facing behavior, shortcuts, command reference, feature usage, and bug-fix-visible behavior changes.
   - Update `README.md` when the feature belongs in the short public overview or command list.
   - Update `TECHNICAL_REPORT.md` when the change is a notable implementation/design change, including nontrivial bug fixes, parsing/highlight rules, or cross-module behavior.
   - For bug fixes, add or revise the smallest relevant note that tells users the corrected behavior.
   - For new features, document how users invoke or benefit from the feature.

4. Keep docs and implementation names exact:
   - Match key notation exactly, for example `,H`, `<localleader>H`, `:ImpetusPreviewGeometry`, or `:Cgeo`.
   - Mention fallback behavior or platform limitations when the command opens external programs or browser pages.
   - If a shortcut has both normal-mode and insert-mode mappings, document both only when users need to know both.
   - When documenting bug fixes, describe the user-visible behavior, not internal helper names.

5. Verify before finishing:
   - Search for stale or missing mentions of the changed key, command, feature, or behavior with `rg`.
   - Run a lightweight Neovim load check when Lua code changed.
   - In the final response, explicitly say which Markdown docs were updated.
   - If the mini help was not updated, state briefly that no shortcut/command/help-popup entry changed.

## Guardrails

- Do not add unrelated documentation rewrites while updating one behavior.
- Do not document internal helper functions unless they are exposed through a keymap, user command, alias, popup, or user workflow.
- Do not leave a new feature or user-visible bug fix undocumented unless the user explicitly requests an internal-only change.
- Keep bug-fix documentation concise; avoid turning every implementation detail into a changelog entry.
