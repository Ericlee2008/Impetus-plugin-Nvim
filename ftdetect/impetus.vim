augroup impetus_filetype
  autocmd!
  autocmd BufNewFile,BufRead *.key,*.k,*.imp,*.inp setlocal filetype=impetus
  autocmd BufNewFile,BufRead commands.help setlocal filetype=impetus
  autocmd FileType kwt if expand('%:e') =~? '^\%(k\|key\|imp\|inp\)$' | setlocal filetype=impetus | endif
augroup END
