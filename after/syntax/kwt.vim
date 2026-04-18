" Reuse impetus syntax groups even when another plugin sets ft=kwt.
if exists("b:current_syntax")
  unlet b:current_syntax
endif

runtime! syntax/impetus.vim
