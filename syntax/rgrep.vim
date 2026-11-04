" vim-rgrep: results syntax.
if exists('b:current_syntax')
  finish
endif

syntax match RgrepPath /^.\{-}\ze:\d\+:\d\+: /
syntax match RgrepLoc /^.\{-}\zs:\d\+:\d\+:/

let b:current_syntax = 'rgrep'
