" vim-rgrep: preview window.
scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

let s:buf = -1
let s:win = 0
let s:item = {}
let s:ft_cache = {}


function! s:cfg_num(name, default) abort
  let value = get(g:, a:name, a:default)
  if type(value) == v:t_number
    return value
  endif
  if exists('v:t_bool') && type(value) == v:t_bool
    return value ? 1 : 0
  endif
  return a:default
endfunction

function! s:win_alive(winid) abort
  return a:winid > 0 && !empty(getwininfo(a:winid))
endfunction

function! s:win_buf(winid) abort
  if a:winid <= 0
    return -1
  endif
  let info = getwininfo(a:winid)
  return empty(info) ? -1 : info[0].bufnr
endfunction

function! s:ensure_buf() abort
  if s:buf > 0 && bufexists(s:buf)
    return s:buf
  endif

  let s:buf = bufadd('')
  call bufload(s:buf)
  call setbufvar(s:buf, '&buftype', 'nofile')
  call setbufvar(s:buf, '&bufhidden', 'hide')
  call setbufvar(s:buf, '&swapfile', 0)
  call setbufvar(s:buf, '&buflisted', 0)
  call setbufvar(s:buf, '&undolevels', -1)
  return s:buf
endfunction

function! s:setup_window() abort
  setlocal buftype=nofile
  setlocal bufhidden=hide
  setlocal noswapfile
  setlocal nobuflisted
  setlocal nolist
  setlocal nospell
  setlocal nomodeline
  setlocal number
  setlocal numberwidth=4
  setlocal norelativenumber
  setlocal signcolumn=no
  setlocal foldcolumn=0
  setlocal foldenable
  setlocal foldmethod=manual
  setlocal undolevels=-1
  setlocal scrolloff=3
  setlocal nocursorline
  setlocal nomodifiable
  setlocal statusline=
  if s:cfg_num('rgrep_preview_wrap', 0)
    setlocal wrap
  else
    setlocal nowrap
  endif
endfunction

function! s:map_preview() abort
  call win_execute(s:win, 'silent! nunmap <buffer> <Esc>')

  let buf = s:buf
  for key in getbufvar(buf, 'rgrep_preview_mapped', [])
    call win_execute(s:win, 'silent! nunmap <buffer> ' . key)
  endfor
  call setbufvar(buf, 'rgrep_preview_mapped', [])

  if !s:cfg_num('rgrep_keymaps_enabled', 1)
    return
  endif

  let maps = rgrep#keymaps()
  let actions = {
        \ 'open_file': ':<C-u>call rgrep#preview#open_file()<CR>',
        \ 'open_file_tab': ':<C-u>call rgrep#preview#open_file()<CR>',
        \ 'search': ':<C-u>call rgrep#search_again()<CR>',
        \ 'filter': ':<C-u>call rgrep#filter()<CR>',
        \ 'quit': ':<C-u>call rgrep#close()<CR>',
        \ }

  let mapped = []
  for [action, rhs] in items(actions)
    let keys = get(maps, action, '')
    if type(keys) != v:t_list
      let keys = [keys]
    endif
    for key in keys
      if type(key) != v:t_string || empty(key)
        continue
      endif
      call win_execute(s:win,
            \ 'silent! nnoremap <buffer> <silent> ' . key . ' ' . rhs)
      call add(mapped, key)
    endfor
  endfor
  call setbufvar(buf, 'rgrep_preview_mapped', mapped)
endfunction

function! s:set_lines(lines) abort
  let nr = s:ensure_buf()
  if s:win_alive(s:win) && s:win_buf(s:win) != nr
    call win_execute(s:win, 'silent! buffer ' . nr)
  endif
  let was_modifiable = getbufvar(nr, '&modifiable')
  call setbufvar(nr, '&modifiable', 1)
  try
    let old = len(getbufline(nr, 1, '$'))
    call setbufline(nr, 1, a:lines)
    if old > len(a:lines)
      silent call deletebufline(nr, len(a:lines) + 1, old)
    endif
    call setbufvar(nr, '&modified', 0)
  finally
    call setbufvar(nr, '&modifiable', was_modifiable)
  endtry
endfunction

function! s:set_filetype(ft) abort
  let ft = type(a:ft) == v:t_string ? a:ft : ''
  if ft !~# '^[A-Za-z0-9_]*$'
    let ft = ''
  endif
  if getbufvar(s:buf, '&filetype') ==# ft
    return
  endif
  call win_execute(s:win, 'setlocal filetype=' . ft)
endfunction

function! s:set_status(path, lnum, offset) abort
  let name = fnamemodify(a:path, ':t')
  let text = substitute(printf(' %s [preview] :%d ', name, a:lnum), '%', '%%', 'g')
  call win_execute(s:win,
        \ 'setlocal ' . (a:offset > 1 ? 'nonumber' : 'number'))
  call win_execute(s:win, 'let &l:statusline = ' . string(text))
endfunction

function! s:place_cursor(lnum) abort
  call win_execute(s:win, 'call cursor(' . a:lnum . ', 1)')
  call win_execute(s:win, 'silent! normal! zz')
endfunction

function! s:highlight(lnum, text, item) abort
  call win_execute(s:win, 'silent! call clearmatches()')

  let text_len = strlen(a:text)
  let line_len = text_len > 0 ? text_len : 1

  try
    call win_execute(s:win, 'call matchaddpos('
          \ . string('RgrepPreviewLine') . ', [['
          \ . a:lnum . ', 1, ' . line_len . ']], 10)')

    let start = a:item.mstart + 1
    if start < 1
      let start = 1
    endif
    if start > text_len
      let start = text_len > 0 ? text_len : 1
    endif

    let length = a:item.mend - a:item.mstart
    if length < 1
      let length = 1
    endif
    if text_len > 0 && start + length - 1 > text_len
      let length = max([1, text_len - start + 1])
    endif

    call win_execute(s:win, 'call matchaddpos('
          \ . string('RgrepPreviewMatch') . ', [['
          \ . a:lnum . ', ' . start . ', ' . length . ']], 20)')
  catch
  endtry
endfunction

function! s:read(path, lnum) abort
  let size = getfsize(a:path)
  let max_bytes = s:cfg_num('rgrep_preview_max_bytes', 2 * 1024 * 1024)
  let full_lines = s:cfg_num('rgrep_preview_full_lines', 3000)
  let context = s:cfg_num('rgrep_preview_context', 150)
  if context < 10
    let context = 10
  endif

  try
    if size >= 0 && size <= max_bytes
      let lines = readfile(a:path)
      if len(lines) <= full_lines
        return [lines, 1]
      endif

      let start = a:lnum > context ? a:lnum - context : 1
      let last = min([len(lines), a:lnum + context])
      if start > len(lines)
        let start = 1
      endif
      if last < start
        let last = start
      endif
      return [lines[start - 1 : last - 1], start]
    endif

    let upto = a:lnum + context + 50
    if upto < 200
      let upto = 200
    endif
    if upto > 200000
      let upto = 200000
    endif

    let head = readfile(a:path, '', upto)
    let start = a:lnum > context ? a:lnum - context : 1
    if start > len(head)
      return [head, 1]
    endif
    return [head[start - 1 :], start]
  catch
    return [[], 1]
  endtry
endfunction

function! s:special_filetypes() abort
  return {
        \ 'Makefile': 'make',
        \ 'makefile': 'make',
        \ 'GNUmakefile': 'make',
        \ 'Dockerfile': 'dockerfile',
        \ 'CMakeLists.txt': 'cmake',
        \ 'Vagrantfile': 'ruby',
        \ 'Gemfile': 'ruby',
        \ 'Rakefile': 'ruby',
        \ 'PKGBUILD': 'sh',
        \ '.gitignore': 'gitignore',
        \ '.gitconfig': 'gitconfig',
        \ '.bashrc': 'sh',
        \ '.bash_profile': 'sh',
        \ '.profile': 'sh',
        \ '.zshrc': 'zsh',
        \ '.vimrc': 'vim',
        \ '.gvimrc': 'vim',
        \ '.env': 'sh',
        \ 'go.mod': 'gomod',
        \ 'go.sum': 'gosum',
        \ }
endfunction

function! s:filetypes() abort
  return {
        \ 'c': 'c',
        \ 'h': 'c',
        \ 'cpp': 'cpp',
        \ 'cc': 'cpp',
        \ 'cxx': 'cpp',
        \ 'hpp': 'cpp',
        \ 'hh': 'cpp',
        \ 'hxx': 'cpp',
        \ 'm': 'objc',
        \ 'mm': 'objc',
        \ 'py': 'python',
        \ 'pyi': 'python',
        \ 'pyw': 'python',
        \ 'js': 'javascript',
        \ 'mjs': 'javascript',
        \ 'cjs': 'javascript',
        \ 'jsx': 'javascriptreact',
        \ 'ts': 'typescript',
        \ 'mts': 'typescript',
        \ 'cts': 'typescript',
        \ 'tsx': 'typescriptreact',
        \ 'vue': 'vue',
        \ 'svelte': 'svelte',
        \ 'go': 'go',
        \ 'rs': 'rust',
        \ 'java': 'java',
        \ 'kt': 'kotlin',
        \ 'kts': 'kotlin',
        \ 'scala': 'scala',
        \ 'groovy': 'groovy',
        \ 'rb': 'ruby',
        \ 'php': 'php',
        \ 'pl': 'perl',
        \ 'pm': 'perl',
        \ 'lua': 'lua',
        \ 'vim': 'vim',
        \ 'sh': 'sh',
        \ 'bash': 'sh',
        \ 'zsh': 'zsh',
        \ 'fish': 'fish',
        \ 'ps1': 'powershell',
        \ 'json': 'json',
        \ 'jsonc': 'jsonc',
        \ 'yaml': 'yaml',
        \ 'yml': 'yaml',
        \ 'toml': 'toml',
        \ 'ini': 'dosini',
        \ 'conf': 'conf',
        \ 'cfg': 'conf',
        \ 'properties': 'jproperties',
        \ 'md': 'markdown',
        \ 'markdown': 'markdown',
        \ 'rst': 'rst',
        \ 'tex': 'tex',
        \ 'html': 'html',
        \ 'htm': 'html',
        \ 'xhtml': 'html',
        \ 'xml': 'xml',
        \ 'svg': 'xml',
        \ 'css': 'css',
        \ 'scss': 'scss',
        \ 'less': 'less',
        \ 'sass': 'sass',
        \ 'sql': 'sql',
        \ 'graphql': 'graphql',
        \ 'proto': 'proto',
        \ 'cmake': 'cmake',
        \ 'txt': 'text',
        \ 'log': 'text',
        \ 'csv': 'csv',
        \ 'tsv': 'tsv',
        \ 'diff': 'diff',
        \ 'patch': 'diff',
        \ }
endfunction

function! s:filetype(path) abort
  if has_key(s:ft_cache, a:path)
    return s:ft_cache[a:path]
  endif

  let ft = ''
  let base = fnamemodify(a:path, ':t')
  let ext = tolower(fnamemodify(a:path, ':e'))

  let custom = get(g:, 'rgrep_filetypes', {})
  if type(custom) == v:t_dict
    if has_key(custom, base)
      let ft = custom[base]
    elseif has_key(custom, ext)
      let ft = custom[ext]
    endif
  endif

  if empty(ft) && has('nvim')
    try
      let ft = luaeval('(function(p) local ok, m = pcall(require, "vim.filetype"); if not ok then return "" end; local ok2, r = pcall(m.match, {filename = p}); if not ok2 or type(r) ~= "string" then return "" end; return r end)(_A)', a:path)
    catch
      let ft = ''
    endtry
  endif

  if empty(ft)
    let special = s:special_filetypes()
    if has_key(special, base)
      let ft = special[base]
    else
      let ft = get(s:filetypes(), ext, '')
    endif
  endif

  if type(ft) != v:t_string
    let ft = ''
  endif

  let s:ft_cache[a:path] = ft
  return ft
endfunction

function! s:set_message(msg) abort
  call s:set_lines([a:msg])
  call win_execute(s:win, 'silent! file ' . fnameescape('rgrep://preview'))
  call win_execute(s:win, 'setlocal filetype=')
  call win_execute(s:win, 'setlocal nonumber norelativenumber')
  call win_execute(s:win, 'silent! call clearmatches()')
  call win_execute(s:win, 'setlocal nomodifiable')
  call win_execute(s:win, 'let &l:statusline = ' . string(' [preview] '))
endfunction


function! rgrep#preview#buf() abort
  return s:buf
endfunction

function! rgrep#preview#win() abort
  return s:win
endfunction

function! rgrep#preview#visible() abort
  return s:win_alive(s:win)
endfunction

function! rgrep#preview#open() abort
  if rgrep#preview#visible()
    return
  endif

  let list_win = rgrep#list_win()
  if !s:win_alive(list_win)
    return
  endif

  let tw = win_id2tabwin(list_win)
  if tw[0] != tabpagenr()
    return
  endif

  if win_getid() != list_win
    call win_gotoid(list_win)
  endif

  let layout = rgrep#layout()
  if layout ==# 'top'
    belowright split
  elseif layout ==# 'left'
    belowright vsplit
  elseif layout ==# 'right'
    leftabove vsplit
  else
    aboveleft split
  endif

  let s:win = win_getid()
  let nr = s:ensure_buf()
  execute 'silent! buffer ' . nr
  if s:win_buf(s:win) != nr
    silent! close!
    let s:win = 0
    return
  endif

  if bufname('%') !=# 'rgrep://preview'
    silent! file rgrep://preview
  endif

  call s:setup_window()
  call s:map_preview()
  call rgrep#resize_list()
  let item = rgrep#current_item()
  if empty(item)
    call rgrep#preview#clear()
  else
    call rgrep#preview#show(item)
  endif

  if win_getid() != list_win
    call win_gotoid(list_win)
  endif
endfunction

function! rgrep#preview#close() abort
  if !rgrep#preview#visible()
    let s:win = 0
    return
  endif

  if win_getid() == s:win
    silent! close!
  else
    call win_execute(s:win, 'silent! close!')
  endif
  let s:win = 0
endfunction

function! rgrep#preview#focus_list() abort
  let win = rgrep#list_win()
  if s:win_alive(win)
    call win_gotoid(win)
  endif
endfunction

function! rgrep#preview#clear() abort
  let s:item = {}
  if !rgrep#preview#visible()
    return
  endif
  call s:set_message('  (no selection)')
endfunction

function! rgrep#preview#open_file() abort
  if empty(s:item)
    return
  endif
  call rgrep#open_item(s:item)
endfunction

function! rgrep#preview#show(item) abort
  if empty(a:item) || !rgrep#preview#visible()
    return
  endif
  let s:item = a:item

  let path = rgrep#abs_path(a:item.path)
  if !filereadable(path)
    call s:set_message('  [cannot preview: ' . a:item.path . ']')
    return
  endif

  let [lines, offset] = s:read(path, a:item.lnum)
  if empty(lines)
    call s:set_message('  [cannot preview: ' . a:item.path . ']')
    return
  endif

  let nr = s:ensure_buf()
  if s:win_buf(s:win) != nr
    call win_execute(s:win, 'silent! buffer ' . nr)
    call s:map_preview()
  endif
  call s:set_lines(lines)
  call s:set_filetype(s:filetype(path))
  call win_execute(s:win,
        \ s:cfg_num('rgrep_preview_wrap', 0) ? 'setlocal wrap' : 'setlocal nowrap')
  call win_execute(s:win, 'setlocal nomodifiable')
  call win_execute(s:win, 'silent! file '
        \ . fnameescape(fnamemodify(path, ':t') . ' [preview]'))

  let disp = a:item.lnum - offset + 1
  if disp < 1
    let disp = 1
  endif
  if disp > len(lines)
    let disp = len(lines)
  endif

  call s:set_status(path, a:item.lnum, offset)
  call s:place_cursor(disp)
  call s:highlight(disp, lines[disp - 1], a:item)
endfunction

function! rgrep#preview#forget() abort
  let s:win = 0
  let s:item = {}
  let s:ft_cache = {}
  if s:buf > 0 && bufexists(s:buf)
    execute 'silent! bwipeout! ' . s:buf
  endif
  let s:buf = -1
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
