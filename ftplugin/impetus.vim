if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

setlocal commentstring=#\ %s
setlocal formatoptions-=t
setlocal omnifunc=v:lua.require'impetus.complete'.omnifunc
setlocal foldmethod=manual
setlocal foldexpr=
setlocal foldtext=v:lua.require'impetus.fold'.foldtext()
setlocal foldlevelstart=99
setlocal foldlevel=99
setlocal foldenable
setlocal fillchars+=fold:\ 
let b:impetus_fold_all_closed = 0

let b:undo_ftplugin = "setlocal commentstring< formatoptions< omnifunc< foldmethod< foldexpr< foldtext< foldlevelstart< foldlevel< foldenable< fillchars<"
