if exists("b:current_syntax")
  finish
endif

syntax match impetusKeyword /^\s*\(\d\+\.\s*\)\?\*[A-Za-z0-9_-]\+/

syntax match impetusControlStart /^\s*\~\(if\|repeat\|convert_from_[A-Za-z0-9_]*\|begin_scope\)\>/
syntax match impetusControlMid /^\s*\~\(else_if\|else\)\>/
syntax match impetusControlEnd /^\s*\~\(end_if\|end_repeat\|end_convert\|end_scope\)\>/
syntax match impetusParam /\[%\h\w*\]/
syntax match impetusParam /%\h\w*/
syntax match impetusRepeatVar /\v\[r[0-9]+\]/
syntax match impetusNumber /\%([[:alnum:]_%.\/\\%]\)\@<![-+]\=\d\+\%(\.\d\+\)\=\%([eE][-+]\=\d\+\)\=\%([[:alnum:]_%.\/\\]\)\@!/
syntax match impetusComment /^\s*[#$].*/
syntax region impetusString start=/"/ end=/"/ keepend
syntax match impetusEmptyField /^\s\+\ze,/ containedin=ALLBUT,impetusComment,impetusString
syntax match impetusEmptyField /,\zs\s\+\ze,/ containedin=ALLBUT,impetusComment,impetusString
syntax match impetusHeader /^\s*Variable\s\+Description\s*$/
syntax match impetusOptions /\<options\>:/ containedin=ALL
syntax match impetusDefault /\<default\>:/ containedin=ALL
" syntax match impetusExample /^\s*[#$]\?\s*\(example\|end\)\s*$/
syntax region impetusExample start=/^\s*[#$]\?\s*example\s*$/ end=/^\s*[#$]\?\s*end\s*$/ keepend
syntax match impetusDivider /^\s*\(\d\+\.\s*\)\?-\{8,}\s*$/
syntax match impetusFieldName /^\s*[[:alnum:]_%%\[\]]\+\s*:\s*/ contains=impetusParam,impetusRepeatVar

" Intrinsic categories (injected by Lua from intrinsic.k):
" impetusIntrinsicFunction / impetusIntrinsicVariable / impetusIntrinsicSymbol
" Hard-code common intrinsic variables so they always highlight even if
" intrinsic.k dynamic injection fails.
" Use explicit alnum boundary (not \< \>) because the user may extend
" iskeyword to include '-' for keywords like *change_p-order.
for s:var in ['pi', 'dt', 't', 'term', 'x', 'y', 'z', 'vx', 'vy', 'vz', 'xnorm', 'ynorm', 'znorm']
  execute 'syntax match impetusIntrinsicVariable /\%([[:alnum:]_]\)\@<!' . s:var . '\%([[:alnum:]_]\)\@!/' 
endfor
unlet s:var

highlight default link impetusKeyword Keyword
highlight default link impetusDirective PreProc

highlight default link impetusControlStart PreProc
highlight default link impetusControlMid Special
highlight default link impetusControlEnd Statement
highlight default link impetusParam Identifier
highlight default link impetusRepeatVar Special
highlight default link impetusNumber Number
highlight default link impetusComment Comment
highlight default link impetusString String
highlight default link impetusEmptyField Visual
highlight default link impetusHeader Title
highlight default link impetusOptions Statement
highlight default link impetusDefault Statement
highlight default link impetusExample Comment
highlight default link impetusDivider Comment
highlight default link impetusFieldName Identifier
highlight default link impetusIntrinsicFunction Function
highlight default link impetusIntrinsicVariable Identifier
highlight default link impetusIntrinsicSymbol Operator

let b:current_syntax = "impetus"
