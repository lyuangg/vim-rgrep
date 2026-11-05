" vim-rgrep: search, render, and batch operations.
scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

let s:sid = expand('<SID>')


function! s:empty_state() abort
  return {
        \ 'active': 0,
        \ 'closing': 0,
        \ 'tab': -1,
        \ 'list_win': 0,
        \ 'list_buf': -1,
        \ 'pattern': '',
        \ 'fixed': 0,
        \ 'root': '',
        \ 'items': [],
        \ 'shown': [],
        \ 'filters': [],
        \ 'index': 0,
        \ 'next_id': 1,
        \ 'deleted': [],
        \ 'gen': 0,
        \ 'job': 0,
        \ 'job_active': 0,
        \ 'cap_timer': -1,
        \ 'render_timer': -1,
        \ 'preview_timer': -1,
        \ 'stderr': [],
        \ 'status': '',
        \ 'truncated': 0,
        \ 'dirty': 0,
        \ 'preview_id': -1,
        \ 'help': 0,
        \ 'help_opened_preview': 0,
        \ 'cmd': [],
        \ 'engine': 'rg',
        \ }
endfunction

let s:st = s:empty_state()
let s:partial = ''
let s:history = []
let s:history_loaded = 0


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

function! s:cfg_str(name, default) abort
  let value = get(g:, a:name, a:default)
  return type(value) == v:t_string ? value : a:default
endfunction

function! s:err(msg) abort
  echohl ErrorMsg
  echomsg 'Rgrep: ' . a:msg
  echohl None
endfunction

function! s:win_alive(winid) abort
  return a:winid > 0 && !empty(getwininfo(a:winid))
endfunction

function! s:tab_current() abort
  if !s:win_alive(s:st.list_win)
    return 0
  endif
  let tw = win_id2tabwin(s:st.list_win)
  return tw[0] > 0 && tw[0] == tabpagenr()
endfunction

function! s:session_alive() abort
  return s:st.active
        \ && s:win_alive(s:st.list_win)
        \ && bufexists(s:st.list_buf)
endfunction

function! s:item_at(idx) abort
  if a:idx < 0 || a:idx >= len(s:st.shown)
    return {}
  endif
  return s:st.shown[a:idx]
endfunction

function! s:find_index(items, id) abort
  let i = 0
  for item in a:items
    if get(item, 'id', -1) == a:id
      return i
    endif
    let i += 1
  endfor
  return -1
endfunction

function! s:unique_files() abort
  let seen = {}
  let files = []
  for item in s:st.shown
    let path = rgrep#abs_path(item.path)
    if !has_key(seen, path)
      let seen[path] = 1
      call add(files, path)
    endif
  endfor
  return files
endfunction

function! s:qf_entries() abort
  let entries = []
  for item in s:st.shown
    call add(entries, {
          \ 'filename': rgrep#abs_path(item.path),
          \ 'lnum': item.lnum,
          \ 'col': item.col,
          \ 'text': item.text,
          \ })
  endfor
  return entries
endfunction

function! s:set_quickfix(title) abort
  let entries = s:qf_entries()
  call setqflist([], 'r', {'title': a:title, 'items': entries})
  return len(entries)
endfunction

function! s:cursor_item() abort
  if bufnr('%') != s:st.list_buf
    return {}
  endif
  return s:item_at(line('.') - 1)
endfunction

function! s:stop_timer(name) abort
  if get(s:st, a:name, -1) != -1
    call timer_stop(s:st[a:name])
    let s:st[a:name] = -1
  endif
endfunction


function! rgrep#layout() abort
  let value = s:cfg_str('rgrep_layout', 'bottom')
  return index(['bottom', 'top', 'left', 'right'], value) >= 0 ? value : 'bottom'
endfunction

function! rgrep#list_win() abort
  return s:st.list_win
endfunction

function! rgrep#current_item() abort
  if !s:st.active
    return {}
  endif
  return s:item_at(s:st.index)
endfunction

function! rgrep#abs_path(path) abort
  if a:path =~# '^[/\\]' || a:path =~# '^\a:[/\\]'
    return a:path
  endif
  let root = empty(s:st.root) ? getcwd() : s:st.root
  return root . '/' . a:path
endfunction

function! s:preview_enabled() abort
  return s:cfg_num('rgrep_preview', 1) ? 1 : 0
endfunction

function! s:rg_bin() abort
  return s:cfg_str('rgrep_bin', 'rg')
endfunction

function! s:grep_bin() abort
  return s:cfg_str('rgrep_grep_bin', 'grep')
endfunction

function! s:pick_engine() abort
  let choice = s:cfg_str('rgrep_engine', 'auto')

  if choice ==# 'grep'
    return executable(s:grep_bin()) ? 'grep' : ''
  endif
  if choice ==# 'rg'
    return executable(s:rg_bin()) ? 'rg' : ''
  endif

  if executable(s:rg_bin())
    return 'rg'
  endif
  if executable(s:grep_bin())
    return 'grep'
  endif
  return ''
endfunction

function! s:max_results() abort
  return s:cfg_num('rgrep_max_results', 10000)
endfunction

function! s:list_height() abort
  let value = s:cfg_num('rgrep_height', 0)
  if value > 0
    return value
  endif
  return max([8, &lines * 30 / 100])
endfunction

function! s:list_width() abort
  let value = s:cfg_num('rgrep_width', 0)
  if value > 0
    return value
  endif
  return max([40, &columns * 35 / 100])
endfunction


function! s:parse_args(args) abort
  let args = copy(a:args)
  let path = ''
  if !empty(args) && s:looks_like_dir(args[-1])
    let path = remove(args, -1)
  endif
  return [join(args, ' '), path]
endfunction

function! rgrep#cmd(bang, ...) abort
  let [pattern, path] = s:parse_args(a:000)

  if empty(pattern)
    let pattern = input('Rgrep: ', s:st.pattern)
  endif
  if empty(pattern)
    return
  endif

  call s:start(pattern, a:bang ? 1 : 0, 0, path)
endfunction

function! rgrep#word(...) abort
  let word = expand('<cword>')
  if empty(word)
    call s:err('no word under cursor')
    return
  endif
  let path = a:0 ? a:1 : ''
  call s:start(word, 1, 0, path)
endfunction

function! rgrep#search_again() abort
  let line = input('Rgrep: ', s:st.pattern)
  if empty(line)
    return
  endif

  let [pattern, path] = s:parse_args(split(line))
  if empty(pattern)
    let pattern = input('Rgrep in ' . (empty(path) ? s:st.root : path) . ': ',
          \ s:st.pattern)
  endif
  if empty(pattern)
    return
  endif

  call s:start(pattern, 0, 0, empty(path) ? s:st.root : path)
endfunction

function! rgrep#close() abort
  if !s:st.active || s:st.closing
    return
  endif
  call s:close_tab()
endfunction

function! rgrep#refresh() abort
  if !s:st.active || empty(s:st.pattern)
    return
  endif
  call s:start(s:st.pattern, s:st.fixed, 1, s:st.root)
endfunction

function! rgrep#last() abort
  call s:load_history()
  if empty(s:history)
    call s:err('no search history')
    return
  endif
  let entry = s:history[0]
  call s:start(entry.pattern, entry.fixed, 0, entry.root)
endfunction

function! rgrep#history() abort
  call s:load_history()
  if empty(s:history)
    call s:err('no search history')
    return
  endif

  let limit = &lines - 5
  if limit < 1
    let limit = 1
  endif
  let entries = s:history[: limit - 1]

  let lines = ['Select a previous search:']
  let i = 1
  for entry in entries
    call add(lines, printf('%d. %s%s  [%s]',
          \ i,
          \ entry.fixed ? '!' : '',
          \ entry.pattern,
          \ fnamemodify(entry.root, ':~')))
    let i += 1
  endfor

  let choice = inputlist(lines)
  if choice <= 0 || choice > len(entries)
    return
  endif

  let entry = entries[choice - 1]
  call s:start(entry.pattern, entry.fixed, 0, entry.root)
endfunction

function! rgrep#info() abort
  let lines = [
        \ 'active: ' . s:st.active,
        \ 'engine: ' . s:st.engine,
        \ 'root: ' . s:st.root,
        \ 'pattern: ' . s:st.pattern,
        \ 'fixed: ' . s:st.fixed,
        \ 'items: ' . len(s:st.items),
        \ 'shown: ' . len(s:st.shown),
        \ 'filters: ' . join(s:st.filters, ' & '),
        \ 'status: ' . s:st.status,
        \ 'job_active: ' . s:st.job_active,
        \ 'truncated: ' . s:st.truncated,
        \ 'stderr: ' . join(s:st.stderr, ' | '),
        \ 'cmd: ' . string(s:st.cmd),
        \ ]
  echo join(lines, "\n")
endfunction


function! s:open_tab() abort
  if s:session_alive()
    let tw = win_id2tabwin(s:st.list_win)
    if tw[0] > 0
      execute 'tabnext ' . tw[0]
      call win_gotoid(s:st.list_win)
      call s:setup_list_buffer()
      call s:map_list_buffer()
      call s:install_autocmds()
      if s:preview_enabled()
        if !rgrep#preview#visible()
          call rgrep#preview#open()
        endif
      elseif rgrep#preview#visible()
        call rgrep#preview#close()
      endif
      return
    endif
  endif
  call s:create_tab()
endfunction

function! s:create_tab() abort
  keepalt tabnew

  let s:st.active = 1
  let s:st.closing = 0
  let s:st.tab = tabpagenr()
  let s:st.list_win = win_getid()
  let s:st.list_buf = bufnr('%')

  execute 'silent! file ' . fnameescape('rgrep://results')

  call s:setup_list_buffer()
  call s:map_list_buffer()
  call s:install_autocmds()

  if s:preview_enabled()
    call rgrep#preview#open()
  endif
endfunction

function! s:setup_list_buffer() abort
  setlocal buftype=nofile
  setlocal bufhidden=wipe
  setlocal noswapfile
  setlocal nobuflisted
  setlocal number
  setlocal numberwidth=4
  setlocal norelativenumber
  setlocal nolist
  setlocal nowrap
  setlocal nospell
  setlocal nomodeline
  setlocal signcolumn=no
  setlocal foldcolumn=0
  setlocal foldenable
  setlocal foldmethod=manual
  setlocal undolevels=-1
  setlocal cursorline
  setlocal scrolloff=2
  setlocal sidescrolloff=0
  setlocal statusline=
  setlocal filetype=rgrep
  setlocal nomodifiable
  setlocal nomodified
  let b:rgrep_list = 1
endfunction

function! s:install_autocmds() abort
  augroup rgrep_tab
    autocmd!
  augroup END
  autocmd rgrep_tab TabEnter * call rgrep#on_tab_enter()

  augroup rgrep_list
    autocmd! * <buffer>
  augroup END
  execute 'autocmd rgrep_list CursorMoved <buffer> call ' . s:sid . 'on_cursor_moved()'
  execute 'autocmd rgrep_list BufWipeout <buffer> call ' . s:sid . 'on_list_wipeout()'
endfunction

function! rgrep#resize_list() abort
  if !s:st.active || !s:tab_current()
    return
  endif
  if !s:win_alive(s:st.list_win)
    return
  endif

  let layout = rgrep#layout()
  if layout ==# 'left' || layout ==# 'right'
    let width = max([1, min([s:list_width(), &columns - 10])])
    try
      call win_execute(s:st.list_win, 'vertical resize ' . width)
    catch
    endtry
  else
    let height = max([1, min([s:list_height(), &lines - 2])])
    try
      call win_execute(s:st.list_win, 'resize ' . height)
    catch
    endtry
  endif
endfunction


function! s:default_keymaps() abort
  return {
        \ 'open_file': '<CR>',
        \ 'open_file_tab': 'o',
        \ 'quit': 'q',
        \ 'toggle_preview': 'p',
        \ 'hide_preview': '',
        \ 'delete': 'd',
        \ 'delete_file': 'D',
        \ 'restore': 'u',
        \ 'filter': 'f',
        \ 'clear_filter': 'F',
        \ 'refresh': 'r',
        \ 'search': 's',
        \ 'quickfix': 'Q',
        \ 'next_file': ']f',
        \ 'prev_file': '[f',
        \ 'history': 'H',
        \ 'help': '?',
        \ }
endfunction

function! s:merged_keymaps() abort
  let maps = s:default_keymaps()
  let user = get(g:, 'rgrep_keymaps', {})
  if type(user) == v:t_dict
    call extend(maps, user, 'force')
  endif
  return maps
endfunction

function! rgrep#keymaps() abort
  return s:merged_keymaps()
endfunction

function! s:key_label(action) abort
  let keys = get(s:merged_keymaps(), a:action, '')
  if type(keys) == v:t_list
    let keys = join(keys, ' / ')
  endif
  return type(keys) == v:t_string ? keys : ''
endfunction

function! s:help_key() abort
  return s:key_label('help')
endfunction

function! s:clear_list_maps() abort
  for key in get(b:, 'rgrep_mapped', [])
    execute 'silent! nunmap <buffer> ' . key
  endfor
  for key in get(b:, 'rgrep_mapped_x', [])
    execute 'silent! xunmap <buffer> ' . key
  endfor
  let b:rgrep_mapped = []
  let b:rgrep_mapped_x = []
endfunction

function! s:map_action(keys, rhs, ...) abort
  let mode = a:0 ? a:1 : 'n'
  let command = mode ==# 'x' ? 'xnoremap' : 'nnoremap'
  let keys = type(a:keys) == v:t_list ? a:keys : [a:keys]
  for key in keys
    if type(key) != v:t_string || empty(key)
      continue
    endif
    " <nowait> prevents a delay when another plugin has a longer global
    " mapping that starts with this key (for example "dm" vs "d").
    execute 'silent! ' . command . ' <buffer> <nowait> <silent> '
          \ . key . ' ' . a:rhs
    if mode ==# 'x'
      let b:rgrep_mapped_x = add(get(b:, 'rgrep_mapped_x', []), key)
    else
      let b:rgrep_mapped = add(get(b:, 'rgrep_mapped', []), key)
    endif
  endfor
endfunction

function! s:map_list_buffer() abort
  call s:clear_list_maps()

  if !s:cfg_num('rgrep_keymaps_enabled', 1)
    return
  endif

  let maps = s:merged_keymaps()

  let actions = {
        \ 'open_file': ':<C-u>call rgrep#open_file()<CR>',
        \ 'open_file_tab': ':<C-u>call rgrep#open_file()<CR>',
        \ 'quit': ':<C-u>call rgrep#close()<CR>',
        \ 'toggle_preview': ':<C-u>call rgrep#toggle_preview()<CR>',
        \ 'hide_preview': ':<C-u>call rgrep#hide_preview()<CR>',
        \ 'delete': ':<C-u>call rgrep#delete()<CR>',
        \ 'delete_file': ':<C-u>call rgrep#delete_file()<CR>',
        \ 'restore': ':<C-u>call rgrep#restore()<CR>',
        \ 'filter': ':<C-u>call rgrep#filter()<CR>',
        \ 'clear_filter': ':<C-u>call rgrep#clear_filter()<CR>',
        \ 'refresh': ':<C-u>call rgrep#refresh()<CR>',
        \ 'search': ':<C-u>call rgrep#search_again()<CR>',
        \ 'quickfix': ':<C-u>RgrepQF!<CR>',
        \ 'next_file': ':<C-u>call rgrep#next_file()<CR>',
        \ 'prev_file': ':<C-u>call rgrep#prev_file()<CR>',
        \ 'history': ':<C-u>RgrepHistory<CR>',
        \ 'help': ':<C-u>call rgrep#toggle_help()<CR>',
        \ }

  for [action, rhs] in items(actions)
    call s:map_action(get(maps, action, ''), rhs)
  endfor

  " Visual mode: delete every selected result row.
  call s:map_action(get(maps, 'delete', ''),
        \ ':<C-u>call rgrep#delete_visual()<CR>', 'x')
endfunction


function! s:start(pattern, fixed, ...) abort
  let engine = s:pick_engine()
  if empty(engine)
    let choice = s:cfg_str('rgrep_engine', 'auto')
    if choice ==# 'grep'
      call s:err('grep not found: ' . s:grep_bin())
    elseif choice ==# 'rg'
      call s:err('ripgrep not found: ' . s:rg_bin())
    else
      call s:err('neither ' . s:rg_bin() . ' nor ' . s:grep_bin() . ' found')
    endif
    return
  endif

  let keep_filter = a:0 ? a:1 : 0
  let root = (a:0 > 1 && !empty(a:2)) ? s:normalize_dir(a:2) : s:root()
  if !isdirectory(root)
    call s:err('not a directory: ' . root)
    return
  endif

  let filters = keep_filter ? copy(s:st.filters) : []

  call s:stop_job()
  call s:stop_timer('cap_timer')
  call s:stop_timer('render_timer')
  call s:stop_timer('preview_timer')

  let s:st.gen += 1
  let s:st.pattern = a:pattern
  let s:st.fixed = a:fixed
  let s:st.root = root
  let s:st.items = []
  let s:st.shown = []
  let s:st.filters = filters
  let s:st.index = 0
  let s:st.deleted = []
  let s:st.stderr = []
  let s:st.truncated = 0
  let s:st.dirty = 0
  let s:st.status = 'searching'
  let s:st.next_id = 1
  let s:st.preview_id = -1
  let s:st.help = 0
  let s:st.help_opened_preview = 0
  let s:st.cmd = []
  let s:st.engine = engine

  call s:add_history(a:pattern, a:fixed, root)

  try
    call s:open_tab()
  catch
    call s:err('setup error: ' . v:exception)
  endtry

  " Start the job before UI setup.
  call s:start_job()
  call s:set_match_syntax()
  call s:render()
  call s:update_preview(1)
endfunction

function! s:normalize_dir(dir) abort
  let dir = expand(a:dir)
  let dir = fnamemodify(dir, ':p')
  let dir = substitute(dir, '[/\\]$', '', '')
  return empty(dir) ? '/' : dir
endfunction

function! s:looks_like_dir(text) abort
  if isdirectory(expand(a:text))
    return 1
  endif
  return a:text ==# '.' || a:text ==# '..' || a:text ==# '~'
        \ || a:text =~# '^\~/'
        \ || a:text =~# '^\.\.\?/'
        \ || a:text =~# '^/'
        \ || a:text =~# '^\a:[/\\]'
endfunction

function! s:root() abort
  let root = s:cfg_str('rgrep_root', '')
  if empty(root)
    let root = getcwd()
  endif
  return s:normalize_dir(root)
endfunction

function! s:history_file() abort
  return expand(s:cfg_str('rgrep_history_file', '~/.rgrep_history'))
endfunction

function! s:history_size() abort
  return s:cfg_num('rgrep_history_size', 50)
endfunction

function! s:load_history() abort
  if s:history_loaded
    return
  endif
  let s:history_loaded = 1

  let file = s:history_file()
  if !filereadable(file)
    return
  endif

  " One JSON object per line.
  try
    for line in readfile(file)
      if empty(line)
        continue
      endif
      try
        let entry = json_decode(line)
      catch
        continue
      endtry
      if type(entry) != v:t_dict
            \ || !has_key(entry, 'pattern')
            \ || type(entry.pattern) != v:t_string
            \ || empty(entry.pattern)
        continue
      endif
      call add(s:history, {
            \ 'pattern': entry.pattern,
            \ 'fixed': get(entry, 'fixed', 0) ? 1 : 0,
            \ 'root': get(entry, 'root', ''),
            \ })
    endfor
  catch
  endtry
endfunction

function! s:save_history() abort
  try
    call writefile(map(copy(s:history), 'json_encode(v:val)'),
          \ s:history_file())
  catch
  endtry
endfunction

function! s:add_history(pattern, fixed, root) abort
  let size = s:history_size()
  if size <= 0
    return
  endif

  call s:load_history()

  call filter(s:history,
        \ 'v:val.pattern !=# a:pattern'
        \ . ' || v:val.fixed != a:fixed'
        \ . ' || v:val.root !=# a:root')

  call insert(s:history, {
        \ 'pattern': a:pattern,
        \ 'fixed': a:fixed,
        \ 'root': a:root,
        \ })
  if len(s:history) > size
    call remove(s:history, size, -1)
  endif

  call s:save_history()
endfunction

function! s:globs() abort
  let globs = []
  if s:cfg_num('rgrep_exclude_git', 1)
    call add(globs, '!.git/')
  endif

  let extra = get(g:, 'rgrep_globs', [])
  if type(extra) == v:t_string
    let extra = [extra]
  endif
  if type(extra) == v:t_list
    for glob in extra
      if type(glob) == v:t_string && !empty(glob)
        call add(globs, glob)
      endif
    endfor
  endif
  return globs
endfunction

function! s:base_args() abort
  let args = [
        \ '--json',
        \ '--color=never',
        \ '--max-columns=' . s:cfg_num('rgrep_max_columns', 500),
        \ '--max-filesize=' . s:cfg_str('rgrep_max_filesize', '5M'),
        \ ]

  for glob in s:globs()
    call add(args, '--glob=' . glob)
  endfor

  return args
endfunction

function! s:grep_ignore_case() abort
  let case = s:cfg_str('rgrep_case', 'smart')
  if case ==# 'ignore'
    return 1
  elseif case ==# 'sensitive'
    return 0
  endif
  return s:st.pattern !~# '[[:upper:]]'
endfunction

function! s:grep_command() abort
  let cmd = [s:grep_bin(), '-r', '-n', '-I', '--color=never']

  if s:st.fixed
    call add(cmd, '-F')
  else
    call add(cmd, '-E')
  endif

  if s:grep_ignore_case()
    call add(cmd, '-i')
  endif

  for glob in s:globs()
    if glob[0] ==# '!'
      let pat = strpart(glob, 1)
      if pat =~# '/$'
        call add(cmd, '--exclude-dir=' . substitute(pat, '/$', '', ''))
      else
        call add(cmd, '--exclude=' . pat)
      endif
    else
      call add(cmd, '--include=' . glob)
    endif
  endfor

  call add(cmd, '-e')
  call add(cmd, s:st.pattern)
  " Pass a path so grep does not read stdin.
  call add(cmd, '.')
  return cmd
endfunction

function! s:build_command() abort
  if s:st.engine ==# 'grep'
    return s:grep_command()
  endif

  let cmd = [s:rg_bin()]
  call extend(cmd, s:base_args())

  if s:st.fixed
    call add(cmd, '--fixed-strings')
  endif

  let case = s:cfg_str('rgrep_case', 'smart')
  if case ==# 'ignore'
    call add(cmd, '--ignore-case')
  elseif case ==# 'sensitive'
    call add(cmd, '--case-sensitive')
  else
    call add(cmd, '--smart-case')
  endif

  let extra = get(g:, 'rgrep_rg_args', [])
  if type(extra) == v:t_string
    let extra = [extra]
  endif
  if type(extra) == v:t_list && !empty(extra)
    call extend(cmd, extra)
  endif

  call add(cmd, '-e')
  call add(cmd, s:st.pattern)
  " Pass a path so rg does not read stdin.
  call add(cmd, '.')
  return cmd
endfunction

function! s:start_job() abort
  let cmd = s:build_command()
  let s:st.cmd = copy(cmd)

  if s:cfg_num('rgrep_sync', 0)
    call s:run_sync(cmd)
    return
  endif

  let s:partial = ''
  let s:st.job_active = 1
  let gen = s:st.gen

  if has('nvim')
    let job = -1
    try
      let job = jobstart(cmd, {
            \ 'cwd': s:st.root,
            \ 'on_stdout': function('s:nvim_out', [gen]),
            \ 'on_stderr': function('s:nvim_err', [gen]),
            \ 'on_exit': function('s:nvim_exit', [gen]),
            \ })
    catch
      let job = -1
    endtry
    if job <= 0
      let s:st.job_active = 0
      let s:st.status = 'error'
      call s:err('failed to start ' . s:rg_bin())
      call s:update_status()
      return
    endif
    let s:st.job = job
  else
    let ok = 0
    try
      let s:st.job = job_start(cmd, {
            \ 'cwd': s:st.root,
            \ 'out_mode': 'nl',
            \ 'err_mode': 'nl',
            \ 'out_cb': function('s:vim_out', [gen]),
            \ 'err_cb': function('s:vim_err', [gen]),
            \ 'exit_cb': function('s:vim_exit', [gen]),
            \ })
      let ok = job_status(s:st.job) !=# 'fail'
    catch
      let ok = 0
    endtry
    if !ok
      let s:st.job_active = 0
      let s:st.status = 'error'
      call s:err('failed to start ' . s:rg_bin())
      call s:update_status()
      return
    endif
  endif
endfunction

function! s:stop_job() abort
  if !s:st.job_active
    return
  endif
  let s:st.job_active = 0
  try
    if has('nvim')
      call jobstop(s:st.job)
    else
      call job_stop(s:st.job)
    endif
  catch
  endtry
  let s:st.job = 0
endfunction

function! s:run_sync(cmd) abort
  let cmdline = 'cd ' . shellescape(s:st.root) . ' && '
        \ . join(map(copy(a:cmd), 'shellescape(v:val)'), ' ')
  try
    let lines = systemlist(cmdline)
    let code = v:shell_error
  catch
    call s:err('failed to run ' . s:rg_bin())
    let s:st.status = 'error'
    call s:update_status()
    return
  endtry

  for line in lines
    call s:handle_output(line)
  endfor
  call s:finish(code)
endfunction

function! s:stop_job_soon() abort
  if !s:st.job_active
    return
  endif
  let gen = s:st.gen
  if exists('*timer_start')
    let s:st.cap_timer = timer_start(0, function('s:stop_job_cb', [gen]))
  else
    call s:stop_job()
    call s:finish(0)
  endif
endfunction

function! s:stop_job_cb(gen, ...) abort
  if a:gen != s:st.gen
    return
  endif
  let s:st.cap_timer = -1
  if !s:st.job_active
    return
  endif
  call s:stop_job()
  call s:finish(0)
endfunction


function! s:vim_out(gen, channel, msg) abort
  if a:gen != s:st.gen || !s:st.active
    return
  endif
  call s:handle_output(a:msg)
endfunction

function! s:vim_err(gen, channel, msg) abort
  if a:gen != s:st.gen || !s:st.active
    return
  endif
  if !empty(a:msg) && len(s:st.stderr) < 20
    call add(s:st.stderr, a:msg)
  endif
endfunction

function! s:vim_exit(gen, job, status) abort
  if a:gen != s:st.gen || !s:st.active || !s:st.job_active
    return
  endif
  call s:finish(a:status)
endfunction

function! s:nvim_out(gen, job, data, event) abort
  if a:gen != s:st.gen || !s:st.active
    return
  endif
  if empty(a:data)
    return
  endif

  let data = a:data
  let data[0] = s:partial . data[0]
  let s:partial = remove(data, -1)
  for line in data
    call s:handle_output(line)
  endfor
endfunction

function! s:nvim_err(gen, job, data, event) abort
  if a:gen != s:st.gen || !s:st.active
    return
  endif
  for line in a:data
    if !empty(line) && len(s:st.stderr) < 20
      call add(s:st.stderr, line)
    endif
  endfor
endfunction

function! s:nvim_exit(gen, job, code, event) abort
  if a:gen != s:st.gen || !s:st.active || !s:st.job_active
    return
  endif
  if !empty(s:partial)
    call s:handle_output(s:partial)
    let s:partial = ''
  endif
  call s:finish(a:code)
endfunction

function! s:handle_grep_line(line) abort
  if empty(a:line)
    return
  endif

  " grep output: path:line:text
  let m = matchlist(a:line, '^\(.\{-}\):\(\d\+\):\(.*\)$')
  if empty(m)
    return
  endif

  let path = substitute(m[1], '^\./', '', '')
  if empty(path)
    return
  endif

  let lnum = str2nr(m[2])
  let text = substitute(m[3], '\r$', '', '')
  let text = substitute(text, "\t", '  ', 'g')

  if s:st.truncated
    return
  endif

  let start = 0
  let end = 1
  if !empty(s:st.pattern)
    try
      if s:st.fixed
        let idx = stridx(text, s:st.pattern)
        if idx >= 0
          let start = idx
          let end = idx + strlen(s:st.pattern)
        endif
      else
        let idx = match(text, s:st.pattern)
        if idx >= 0
          let start = idx
          let end = matchend(text, s:st.pattern)
        endif
      endif
    catch
    endtry
  endif
  if end <= start
    let end = start + 1
  endif

  call add(s:st.items, {
        \ 'id': s:st.next_id,
        \ 'path': path,
        \ 'lnum': lnum,
        \ 'col': start + 1,
        \ 'mstart': start,
        \ 'mend': end,
        \ 'text': text,
        \ })
  let s:st.next_id += 1

  let max = s:max_results()
  if max > 0 && len(s:st.items) >= max
    let s:st.truncated = 1
    call s:stop_job_soon()
  endif

  call s:schedule_render()
endfunction

function! s:handle_output(line) abort
  if s:cfg_num('rgrep_debug', 0)
    call writefile([s:st.engine . ':' . strpart(a:line, 0, 200)],
          \ expand('~/.rgrep.log'), 'a')
  endif
  if s:st.engine ==# 'grep'
    call s:handle_grep_line(a:line)
  else
    call s:handle_line(a:line)
  endif
endfunction

function! s:handle_line(line) abort
  if empty(a:line)
    return
  endif

  try
    let ev = json_decode(a:line)
  catch
    return
  endtry

  if type(ev) != v:t_dict || get(ev, 'type', '') !=# 'match'
    return
  endif

  let data = get(ev, 'data', {})
  if type(data) != v:t_dict
    return
  endif

  let path_obj = get(data, 'path', {})
  if type(path_obj) != v:t_dict
    return
  endif
  let path = get(path_obj, 'text', '')
  if type(path) != v:t_string || empty(path)
    return
  endif
  let path = substitute(path, '^\./', '', '')

  let lines_obj = get(data, 'lines', {})
  let text = type(lines_obj) == v:t_dict ? get(lines_obj, 'text', '') : ''
  if type(text) != v:t_string
    let text = ''
  endif
  let text = substitute(text, '\r\?\n$', '', '')
  let text = substitute(text, "\t", '  ', 'g')

  let subs = get(data, 'submatches', [])
  let sub = (type(subs) == v:t_list && !empty(subs) && type(subs[0]) == v:t_dict)
        \ ? subs[0] : {}

  let start = get(sub, 'start', 0)
  let end = get(sub, 'end', 0)
  if type(start) != v:t_number
    let start = 0
  endif
  if type(end) != v:t_number
    let end = start + 1
  endif
  if end <= start
    let end = start + 1
  endif

  let lnum = get(data, 'line_number', 0)
  if type(lnum) != v:t_number
    let lnum = 0
  endif

  if s:st.truncated
    return
  endif

  call add(s:st.items, {
        \ 'id': s:st.next_id,
        \ 'path': path,
        \ 'lnum': lnum,
        \ 'col': start + 1,
        \ 'mstart': start,
        \ 'mend': end,
        \ 'text': text,
        \ })
  let s:st.next_id += 1

  let max = s:max_results()
  if max > 0 && len(s:st.items) >= max
    let s:st.truncated = 1
    call s:stop_job_soon()
  endif

  call s:schedule_render()
endfunction

function! s:finish(code) abort
  if !s:st.active || s:st.closing
    return
  endif

  let s:st.job_active = 0
  let s:st.job = 0

  if s:st.truncated
    let s:st.status = 'truncated at ' . len(s:st.items)
  elseif a:code == 0
    let s:st.status = empty(s:st.items) ? 'no results' : 'done'
  elseif a:code == 1
    let s:st.status = 'no results'
  else
    let s:st.status = 'error(' . a:code . ')'
    if !empty(s:st.stderr)
      call s:err(join(s:st.stderr, ' '))
    else
      call s:err('rg exited with status ' . a:code)
    endif
  endif

  if empty(s:st.items) && (a:code == 0 || a:code == 1)
    echomsg 'Rgrep: no results in ' . s:st.root . ' for ' . s:st.pattern
  endif

  call s:render()
  call s:update_preview(1)
endfunction


function! s:schedule_render() abort
  if s:st.render_timer != -1
    return
  endif

  let delay = s:cfg_num('rgrep_render_ms', 50)
  if !exists('*timer_start') || delay <= 0
    call s:render()
    return
  endif

  let s:st.render_timer = timer_start(delay, function('s:render_cb'))
endfunction

function! s:render_cb(...) abort
  let s:st.render_timer = -1
  call s:render()
endfunction

function! s:render() abort
  if !s:st.active || s:st.closing || !s:session_alive()
    return
  endif

  if !s:tab_current()
    let s:st.dirty = 1
    return
  endif
  let s:st.dirty = 0

  let prev = s:item_at(s:st.index)
  let s:st.shown = s:filtered()

  let lines = []
  for item in s:st.shown
    call add(lines, printf('%s:%d:%d: %s',
          \ item.path, item.lnum, item.col, item.text))
  endfor

  if empty(lines)
    call add(lines, empty(s:st.items)
          \ ? '  (no results)'
          \ : '  (no results match the filter)')
  endif

  call s:set_buffer_lines(s:st.list_buf, lines)

  if !empty(prev)
    let idx = s:find_index(s:st.shown, prev.id)
    if idx >= 0
      let s:st.index = idx
    endif
  endif

  let last = len(s:st.shown) - 1
  if s:st.index > last
    let s:st.index = last
  endif
  if s:st.index < 0
    let s:st.index = 0
  endif

  call s:set_list_cursor(s:st.index + 1)
  call s:update_status()
  call s:schedule_preview()
endfunction

function! s:filtered() abort
  if empty(s:st.filters)
    return copy(s:st.items)
  endif

  let out = []
  for item in s:st.items
    let ok = 1
    for pattern in s:st.filters
      let negate = 0
      let body = pattern
      if !empty(body) && body[0] ==# '!'
        let negate = 1
        let body = strpart(body, 1)
      endif

      let hit = item.path =~? body || item.text =~? body
      if (negate && hit) || (!negate && !hit)
        let ok = 0
        break
      endif
    endfor
    if ok
      call add(out, item)
    endif
  endfor
  return out
endfunction

function! s:set_buffer_lines(buf, lines) abort
  if !bufexists(a:buf)
    return
  endif

  let was_modifiable = getbufvar(a:buf, '&modifiable')
  call setbufvar(a:buf, '&modifiable', 1)
  try
    let old = len(getbufline(a:buf, 1, '$'))
    call setbufline(a:buf, 1, a:lines)
    if old > len(a:lines)
      silent call deletebufline(a:buf, len(a:lines) + 1, old)
    endif
    call setbufvar(a:buf, '&modified', 0)
  finally
    call setbufvar(a:buf, '&modifiable', was_modifiable ? 1 : 0)
  endtry
endfunction

function! s:delete_buffer_lines(buf, first, last) abort
  if !bufexists(a:buf) || a:first < 1 || a:last < a:first
    return
  endif

  let was_modifiable = getbufvar(a:buf, '&modifiable')
  call setbufvar(a:buf, '&modifiable', 1)
  try
    silent call deletebufline(a:buf, a:first, a:last)
    call setbufvar(a:buf, '&modified', 0)
  finally
    call setbufvar(a:buf, '&modifiable', was_modifiable ? 1 : 0)
  endtry
endfunction

function! s:set_list_cursor(lnum) abort
  if !s:tab_current() || !s:win_alive(s:st.list_win)
    return
  endif
  call win_execute(s:st.list_win, 'call cursor(' . a:lnum . ', 1)')
endfunction

function! s:goto_index(idx) abort
  if a:idx < 0 || a:idx >= len(s:st.shown)
    return
  endif
  let s:st.index = a:idx
  call s:set_list_cursor(a:idx + 1)
  call s:schedule_preview()
endfunction

function! s:update_status() abort
  if !s:st.active || !s:tab_current()
    return
  endif
  if !s:cfg_num('rgrep_statusline', 1)
    call win_execute(s:st.list_win, 'setlocal statusline=')
    return
  endif

  let shown = len(s:st.shown)
  let total = len(s:st.items)

  let text = ' Rgrep'
  if !empty(s:st.pattern)
    let text .= ' ' . s:st.pattern
  endif
  " Show "shown/total" only when they differ or a filter is active; this
  " avoids the confusing "42/42" display in the common unfiltered case.
  if !empty(s:st.filters) || shown != total
    let text .= printf('  %d/%d matches', shown, total)
  else
    let text .= printf('  %d matches', total)
  endif
  if !empty(s:st.filters)
    let text .= '  filter:' . join(s:st.filters, ' & ')
  endif
  if !empty(s:st.status)
    let text .= '  ' . s:st.status
  endif
  if s:cfg_num('rgrep_keymaps_enabled', 1)
    let help_key = s:help_key()
    if !empty(help_key)
      let text .= '  ' . help_key . (s:st.help ? ' hide help' : ' help')
    endif
  endif
  let text .= ' '

  let text = substitute(text, '%', '%%', 'g')
  call win_execute(s:st.list_win, 'let &l:statusline = ' . string(text))
endfunction

function! s:set_match_syntax() abort
  if !s:tab_current()
    return
  endif

  call win_execute(s:st.list_win, 'silent! syntax clear RgrepMatch')
  if empty(s:st.pattern)
    return
  endif

  let pattern = s:st.pattern
  if s:st.fixed
    let pattern = '\V' . escape(pattern, '\')
  endif
  let pattern = s:case_prefix() . escape(pattern, '/')

  try
    call win_execute(s:st.list_win,
          \ 'syntax match RgrepMatch /' . pattern . '/')
  catch
  endtry
endfunction

function! s:case_prefix() abort
  let case = s:cfg_str('rgrep_case', 'smart')
  if case ==# 'ignore'
    return '\c'
  elseif case ==# 'sensitive'
    return '\C'
  endif
  return s:st.pattern =~# '[[:upper:]]' ? '\C' : '\c'
endfunction


function! s:on_cursor_moved() abort
  if !s:st.active || s:st.closing
    return
  endif
  if bufnr('%') != s:st.list_buf
    return
  endif

  let idx = line('.') - 1
  if idx < 0 || idx >= len(s:st.shown)
    return
  endif
  if idx == s:st.index
    return
  endif

  let s:st.index = idx
  call s:schedule_preview()
endfunction

function! s:schedule_preview() abort
  if s:st.help
    return
  endif

  let delay = s:cfg_num('rgrep_preview_debounce_ms', 30)
  if !exists('*timer_start') || delay <= 0
    call s:update_preview()
    return
  endif

  if s:st.preview_timer != -1
    call timer_stop(s:st.preview_timer)
  endif
  let s:st.preview_timer = timer_start(delay, function('s:preview_cb'))
endfunction

function! s:preview_cb(...) abort
  let s:st.preview_timer = -1
  call s:update_preview()
endfunction

function! s:update_preview(...) abort
  if !s:st.active || s:st.closing || s:st.help
    return
  endif
  if !rgrep#preview#visible() || !s:tab_current()
    return
  endif

  let item = s:item_at(s:st.index)
  if empty(item)
    if s:st.preview_id != -1
      let s:st.preview_id = -1
      call rgrep#preview#clear()
    endif
    return
  endif

  let force = a:0 ? a:1 : 0
  if !force && s:st.preview_id == item.id
    return
  endif

  let s:st.preview_id = item.id
  call rgrep#preview#show(item)
endfunction

function! rgrep#on_tab_enter() abort
  if !s:st.active || s:st.closing
    return
  endif
  if !s:tab_current()
    return
  endif

  if s:st.dirty
    call s:render()
  endif
  call s:update_status()
  call s:update_preview(1)
endfunction


function! s:find_open_tab() abort
  for tabnr in range(1, tabpagenr('$'))
    if gettabvar(tabnr, 'rgrep_open_tab', 0)
      return tabnr
    endif
  endfor
  return 0
endfunction

function! s:open_path(path, lnum, col) abort
  let lnum = a:lnum > 0 ? a:lnum : 1
  let col = a:col > 0 ? a:col : 1

  if s:cfg_str('rgrep_open_mode', 'tab') ==# 'shared'
    let tabnr = s:find_open_tab()
    if tabnr <= 0
      execute 'keepalt tabedit +' . lnum . ' ' . fnameescape(a:path)
      call settabvar(tabpagenr(), 'rgrep_open_tab', 1)
    else
      execute 'tabnext ' . tabnr
      let nr = bufnr(a:path)
      if nr > 0 && bufexists(nr)
        execute 'hide buffer ' . nr
      else
        execute 'hide edit +' . lnum . ' ' . fnameescape(a:path)
      endif
    endif
  else
    execute 'keepalt tabedit +' . lnum . ' ' . fnameescape(a:path)
  endif

  if lnum <= line('$')
    call cursor(lnum, col)
  endif
  silent! normal! zz
endfunction

function! rgrep#open_item(item) abort
  if !s:st.active || empty(a:item)
    return
  endif

  let path = rgrep#abs_path(a:item.path)
  if !filereadable(path)
    call s:err('file not found: ' . a:item.path)
    return
  endif

  call s:open_path(path, a:item.lnum, a:item.col)
endfunction

function! rgrep#open_file() abort
  if !s:st.active || !s:tab_current()
    return
  endif

  let item = s:cursor_item()
  if empty(item)
    return
  endif

  let s:st.index = line('.') - 1
  call rgrep#open_item(item)
endfunction

function! rgrep#delete() abort
  if !s:st.active || !s:tab_current()
    return
  endif

  let idx = line('.') - 1
  if idx < 0 || idx >= len(s:st.shown)
    return
  endif

  let item = s:st.shown[idx]
  " Without a filter, shown mirrors items one-to-one, so the item's base
  " index is the buffer line index. With a filter, look it up once.
  let base = idx
  if !empty(s:st.filters) || idx >= len(s:st.items)
        \ || s:st.items[idx].id != item.id
    let base = s:find_index(s:st.items, item.id)
  endif
  if base < 0
    return
  endif

  call remove(s:st.items, base)
  call remove(s:st.shown, idx)
  call add(s:st.deleted, {'item': item, 'index': base})

  let s:st.index = idx
  if s:st.index >= len(s:st.shown)
    let s:st.index = len(s:st.shown) - 1
  endif
  if s:st.index < 0
    let s:st.index = 0
  endif

  if empty(s:st.shown)
    " The buffer must switch to the "(no results)" placeholder.
    call s:render()
  else
    " Fast path: remove only the affected buffer line instead of rebuilding
    " the complete result list on every deletion.
    call s:delete_buffer_lines(s:st.list_buf, idx + 1, idx + 1)
    call s:set_list_cursor(s:st.index + 1)
    call s:update_status()
  endif

  " Update the preview asynchronously so deleting never waits for a large
  " file to be re-read and re-highlighted.
  call s:schedule_preview()
endfunction

function! rgrep#delete_visual() abort
  if !s:st.active || !s:tab_current()
    return
  endif

  let first = min([line("'<"), line("'>")]) - 1
  let last = max([line("'<"), line("'>")]) - 1
  if first < 0 || last < first || first >= len(s:st.shown)
    return
  endif
  if last >= len(s:st.shown)
    let last = len(s:st.shown) - 1
  endif
  if last < first
    return
  endif

  let selected = s:st.shown[first : last]
  if empty(selected)
    return
  endif

  let ids = {}
  for item in selected
    let ids[item.id] = 1
  endfor

  let kept = []
  let removed = []
  let base = -1
  for item in s:st.items
    if has_key(ids, item.id)
      if base < 0
        let base = len(kept)
      endif
      call add(removed, item)
    else
      call add(kept, item)
    endif
  endfor
  if empty(removed)
    return
  endif
  let s:st.items = kept

  call remove(s:st.shown, first, last)
  call add(s:st.deleted, {'items': removed, 'index': base})

  let s:st.index = first
  if s:st.index >= len(s:st.shown)
    let s:st.index = len(s:st.shown) - 1
  endif
  if s:st.index < 0
    let s:st.index = 0
  endif

  if empty(s:st.shown)
    call s:render()
  else
    call s:delete_buffer_lines(s:st.list_buf, first + 1, last + 1)
    call s:set_list_cursor(s:st.index + 1)
    call s:update_status()
  endif

  call s:schedule_preview()
endfunction

function! rgrep#delete_file() abort
  if !s:st.active || !s:tab_current()
    return
  endif

  let idx = line('.') - 1
  if idx < 0 || idx >= len(s:st.shown)
    return
  endif

  let path = s:st.shown[idx].path

  let line_idxs = []
  let i = 0
  for item in s:st.shown
    if item.path ==# path
      call add(line_idxs, i)
    endif
    let i += 1
  endfor
  if empty(line_idxs)
    return
  endif

  " Rebuild items without this path instead of removing entries one by one.
  let kept = []
  let removed = []
  let start = -1
  for item in s:st.items
    if item.path ==# path
      if start < 0
        let start = len(kept)
      endif
      call add(removed, item)
    else
      call add(kept, item)
    endif
  endfor
  if empty(removed)
    return
  endif
  let s:st.items = kept

  let last = len(line_idxs) - 1
  while last >= 0
    call remove(s:st.shown, line_idxs[last])
    let last -= 1
  endwhile

  call add(s:st.deleted, {'items': removed, 'index': start})
  let s:st.index = idx
  if s:st.index >= len(s:st.shown)
    let s:st.index = len(s:st.shown) - 1
  endif
  if s:st.index < 0
    let s:st.index = 0
  endif

  if empty(s:st.shown)
    call s:render()
  else
    " Delete in reverse order so earlier buffer line numbers stay valid.
    let last = len(line_idxs) - 1
    while last >= 0
      call s:delete_buffer_lines(
            \ s:st.list_buf, line_idxs[last] + 1, line_idxs[last] + 1)
      let last -= 1
    endwhile
    call s:set_list_cursor(s:st.index + 1)
    call s:update_status()
  endif

  call s:schedule_preview()
endfunction

function! rgrep#restore() abort
  if !s:st.active || empty(s:st.deleted)
    return
  endif

  let entry = remove(s:st.deleted, -1)

  if has_key(entry, 'items')
    let idx = min([entry.index, len(s:st.items)])
    for item in entry.items
      call insert(s:st.items, item, idx)
      let idx += 1
    endfor
    let target = entry.items[0]
  else
    let idx = min([entry.index, len(s:st.items)])
    call insert(s:st.items, entry.item, idx)
    let target = entry.item
  endif

  call s:render()
  let idx = s:find_index(s:st.shown, target.id)
  if idx >= 0
    let s:st.index = idx
    call s:set_list_cursor(idx + 1)
  endif
  call s:update_preview(1)
endfunction

function! rgrep#next_file() abort
  if !s:st.active || !s:tab_current()
    return
  endif

  let idx = line('.') - 1
  if idx < 0 || idx >= len(s:st.shown)
    return
  endif

  let path = s:st.shown[idx].path
  let i = idx + 1
  while i < len(s:st.shown)
    if s:st.shown[i].path !=# path
      call s:goto_index(i)
      return
    endif
    let i += 1
  endwhile
endfunction

function! rgrep#prev_file() abort
  if !s:st.active || !s:tab_current()
    return
  endif

  let idx = line('.') - 1
  if idx <= 0 || idx >= len(s:st.shown)
    return
  endif

  let path = s:st.shown[idx].path
  let i = idx - 1
  while i >= 0 && s:st.shown[i].path ==# path
    let i -= 1
  endwhile
  if i < 0
    return
  endif

  let target_path = s:st.shown[i].path
  while i > 0 && s:st.shown[i - 1].path ==# target_path
    let i -= 1
  endwhile

  call s:goto_index(i)
endfunction

function! rgrep#filter() abort
  if !s:st.active || !s:tab_current()
    return
  endif

  let pattern = input('Add filter (empty cancels, !pattern excludes): ')
  if empty(pattern)
    return
  endif

  let body = pattern
  if body[0] ==# '!'
    let body = strpart(body, 1)
  endif
  if empty(body)
    return
  endif

  try
    call match('', body)
  catch
    call s:err('invalid filter regex: ' . body)
    return
  endtry

  call add(s:st.filters, pattern)
  call s:render()
  call s:update_preview(1)
endfunction

function! rgrep#clear_filter() abort
  if !s:st.active || empty(s:st.filters)
    return
  endif

  let s:st.filters = []
  call s:render()
  call s:update_preview(1)
endfunction

function! s:help_lines() abort
  let rows = []
  for [action, desc] in [
        \ ['help', 'toggle this help'],
        \ ['open_file', 'open selected result'],
        \ ['quit', 'close search tab'],
        \ ['toggle_preview', 'show / hide preview'],
        \ ['hide_preview', 'hide preview'],
        \ ['delete', 'remove current result'],
        \ ['delete_file', 'remove all results of current file'],
        \ ['restore', 'restore last removed result'],
        \ ['filter', 'add filter (!pattern excludes)'],
        \ ['clear_filter', 'clear all filters'],
        \ ['next_file', 'next file'],
        \ ['prev_file', 'previous file'],
        \ ['search', 'new search (pattern [dir])'],
        \ ['refresh', 're-run current search'],
        \ ['history', 'choose from search history'],
        \ ['quickfix', 'send results to quickfix'],
        \ ]
    let key = s:key_label(action)
    if !empty(key)
      call add(rows, [key, desc])
    endif
  endfor

  let lines = [
        \ '',
        \ '  Rgrep keymaps',
        \ '  -------------',
        \ '',
        \ ]
  for [key, desc] in rows
    call add(lines, printf('  %-16s %s', key, desc))
  endfor

  call extend(lines, [
        \ '',
        \ '  Built-in',
        \ '  --------',
        \ '  j / k            move selection',
        \ '  gg / G           first / last result',
        \ '  <C-d> / <C-u>    half page',
        \ '  /                Vim search in results',
        \ '  V + motion       select results, then press the delete',
        \ '                   key to remove all selected results',
        \ '',
        \ '  Statusline: shown/total matches; a single number',
        \ '  means no filter is active.',
        \ '',
        \ ])

  let key = s:help_key()
  if !empty(key)
    call add(lines, '  Press ' . key . ' again to hide this help.')
  endif
  return lines
endfunction

function! rgrep#toggle_help() abort
  if !s:st.active
    return
  endif

  if s:st.help && rgrep#preview#visible()
    let s:st.help = 0
    let opened = s:st.help_opened_preview
    let s:st.help_opened_preview = 0
    if opened && !s:preview_enabled()
      call rgrep#preview#close()
    else
      call s:update_preview(1)
    endif
    call s:update_status()
    return
  endif

  let s:st.help = 0
  let s:st.help_opened_preview = 0
  let was_visible = rgrep#preview#visible()
  if !was_visible
    call rgrep#preview#open()
    if !rgrep#preview#visible()
      call s:err('cannot open the help window')
      return
    endif
  endif

  let s:st.help = 1
  let s:st.help_opened_preview = was_visible ? 0 : 1
  call rgrep#preview#show_help(s:help_lines())
  call s:update_status()
endfunction

function! rgrep#toggle_preview() abort
  if !s:st.active
    return
  endif

  if s:st.help
    let s:st.help = 0
    let s:st.help_opened_preview = 0
    call s:update_status()
  endif

  if rgrep#preview#visible()
    call rgrep#preview#close()
  else
    call rgrep#preview#open()
  endif
endfunction

function! rgrep#hide_preview() abort
  if !s:st.active
    return
  endif

  if s:st.help
    let s:st.help = 0
    let s:st.help_opened_preview = 0
    call s:update_status()
  endif

  if rgrep#preview#visible()
    call rgrep#preview#close()
  endif
endfunction


function! rgrep#quickfix(open) abort
  if !s:st.active || empty(s:st.shown)
    call s:err('no results to send')
    return
  endif

  let total = s:set_quickfix('Rgrep: ' . s:st.pattern)
  echomsg printf('Rgrep: %d item(s) in the quickfix list', total)

  if a:open
    botright copen
  endif
endfunction

function! rgrep#args() abort
  if !s:st.active || empty(s:st.shown)
    call s:err('no results to send')
    return
  endif

  let files = s:unique_files()
  execute 'args ' . join(map(copy(files), 'fnameescape(v:val)'), ' ')
  echomsg printf('Rgrep: %d file(s) in the argument list', len(files))
endfunction

function! rgrep#open_all() abort
  if !s:st.active || empty(s:st.shown)
    call s:err('no results to open')
    return
  endif

  let files = s:unique_files()
  let limit = s:cfg_num('rgrep_open_all_limit', 10)
  if limit > 0 && len(files) > limit
    if confirm(printf('Open %d files in new tabs?', len(files)),
          \ "&Yes\n&No") != 1
      return
    endif
  endif

  let first_line = {}
  for item in s:st.shown
    let path = rgrep#abs_path(item.path)
    if !has_key(first_line, path)
      let first_line[path] = item.lnum > 0 ? item.lnum : 1
    endif
  endfor

  for path in files
    call s:open_path(path, first_line[path], 1)
  endfor
endfunction

function! rgrep#replace() abort
  if !s:st.active || empty(s:st.shown)
    call s:err('no results to replace')
    return
  endif

  let from = input('Replace regex (empty cancels): ',
        \ s:st.fixed ? '\V' . escape(s:st.pattern, '\') : s:st.pattern)
  if empty(from)
    return
  endif

  try
    call match('', from)
  catch
    call s:err('invalid replace regex: ' . from)
    return
  endtry

  let to = input('Replace with: ')

  let files = s:unique_files()
  let modified = []
  for path in files
    let nr = bufnr(path)
    if nr > 0 && getbufvar(nr, '&modified')
      call add(modified, fnamemodify(path, ':t'))
    endif
  endfor
  if !empty(modified)
    call s:err('save modified buffers first: ' . join(modified, ', '))
    return
  endif

  if s:cfg_num('rgrep_replace_confirm', 1)
    let prompt = printf('Replace on %d matched line(s) in %d file(s)?',
          \ len(s:st.shown), len(files))
    if confirm(prompt, "&Yes\n&No") != 1
      return
    endif
  endif

  let total = s:set_quickfix('Rgrep replace: ' . s:st.pattern)
  let replace = 'call setline(".", substitute(getline("."), '
        \ . string(from) . ', ' . string(to) . ', "g"))'

  let saved_hidden = &hidden
  set hidden
  tabnew
  try
    execute 'silent cdo ' . replace
    execute 'silent cfdo update'
  catch
    call s:err('replace failed: ' . v:exception)
  finally
    silent! tabclose
    let &hidden = saved_hidden
  endtry

  echomsg printf('Rgrep: replaced on %d line(s); press r to refresh the search',
        \ total)
endfunction


function! s:find_tab() abort
  for win in [s:st.list_win, rgrep#preview#win()]
    if win > 0 && !empty(getwininfo(win))
      let tw = win_id2tabwin(win)
      if tw[0] > 0
        return tw[0]
      endif
    endif
  endfor
  return 0
endfunction

function! s:close_tab() abort
  if s:st.closing
    return
  endif
  let s:st.closing = 1

  call s:stop_job()
  call s:stop_timer('cap_timer')
  call s:stop_timer('render_timer')
  call s:stop_timer('preview_timer')

  let tabnr = s:find_tab()
  let list_buf = s:st.list_buf
  let preview_buf = rgrep#preview#buf()

  if tabnr > 0 && tabpagenr('$') > 1
    execute 'silent! tabclose ' . tabnr
  elseif tabnr > 0
    if rgrep#preview#visible()
      call rgrep#preview#close()
    endif
    silent! enew
  endif

  call rgrep#preview#forget()

  if list_buf > 0 && bufexists(list_buf)
    execute 'silent! bwipeout! ' . list_buf
  endif
  if preview_buf > 0 && bufexists(preview_buf)
    execute 'silent! bwipeout! ' . preview_buf
  endif

  augroup rgrep_tab
    autocmd!
  augroup END
  augroup rgrep_list
    autocmd!
  augroup END

  let gen = s:st.gen + 1
  let s:st = s:empty_state()
  let s:st.gen = gen
endfunction

function! s:on_list_wipeout() abort
  if s:st.closing || !s:st.active
    return
  endif
  let buf = s:st.list_buf
  if exists('*timer_start')
    call timer_start(0, function('s:wipe_cleanup_cb', [buf]))
  else
    call s:wipe_cleanup(buf)
  endif
endfunction

function! s:wipe_cleanup_cb(buf, ...) abort
  if s:st.list_buf != a:buf
    return
  endif
  call s:wipe_cleanup(a:buf)
endfunction

function! s:wipe_cleanup(buf) abort
  if s:st.closing || !s:st.active
    return
  endif
  if s:st.list_buf != a:buf
    return
  endif
  let s:st.list_buf = -1
  let s:st.list_win = 0
  call s:close_tab()
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
