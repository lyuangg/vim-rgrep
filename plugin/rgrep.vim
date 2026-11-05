" vim-rgrep: commands, highlights, and <Plug> mappings.
if exists('g:loaded_rgrep')
  finish
endif
let g:loaded_rgrep = 1

let s:sid = expand('<SID>')

function! s:define_highlights() abort
  highlight default link RgrepPath Directory
  highlight default link RgrepLoc LineNr
  " Use dedicated colors instead of linking to Search, so rgrep hits remain
  " distinguishable from Vim's own search highlighting.
  highlight default RgrepMatch
        \ ctermfg=16 ctermbg=45 cterm=bold
        \ guifg=#001a1a guibg=#00d7d7 gui=bold
  highlight default link RgrepPreviewLine Visual
  highlight default RgrepPreviewMatch
        \ ctermfg=16 ctermbg=214 cterm=bold
        \ guifg=#2b1a00 guibg=#ffaf5f gui=bold
endfunction

augroup rgrep_highlights
  autocmd!
  execute 'autocmd ColorScheme * call ' . s:sid . 'define_highlights()'
augroup END

call s:define_highlights()

command! -bang -nargs=* Rgrep call rgrep#cmd(<bang>0, <f-args>)
command! -nargs=? -complete=dir RgrepWord call rgrep#word(<f-args>)
command! -nargs=0 RgrepClose call rgrep#close()
command! -nargs=0 RgrepRefresh call rgrep#refresh()
command! -nargs=0 RgrepInfo call rgrep#info()
command! -nargs=0 RgrepLast call rgrep#last()
command! -nargs=0 RgrepHistory call rgrep#history()
command! -bang -nargs=0 RgrepQF call rgrep#quickfix(<bang>0)
command! -nargs=0 RgrepArgs call rgrep#args()
command! -nargs=0 RgrepOpenAll call rgrep#open_all()
command! -nargs=0 RgrepReplace call rgrep#replace()

nnoremap <silent> <Plug>(rgrep) :<C-u>Rgrep<CR>
nnoremap <silent> <Plug>(rgrep-word) :<C-u>RgrepWord<CR>
