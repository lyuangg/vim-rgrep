# vim-rgrep

Recursive search for Vim/Neovim. It runs ripgrep (`rg`) or `grep`, displays
matches and a live preview in a dedicated tab, and opens files without
changing the result view.

[中文说明](README.zh-CN.md)

## Features

- Recursive keyword or regular-expression search from a directory.
- `rg` is used when available; `grep` is used as a fallback.
- Results and preview occupy a dedicated tab. The result list can be placed at
  the bottom, top, left, or right; the preview takes the opposite side.
- The preview follows the selection. `<CR>` opens the selected file.
- Files open in one tab per file or in one shared tab
  (`g:rgrep_open_mode`).
- Result filtering with multiple AND conditions and negative conditions
  (`!pattern`).
- Delete one result or all results of one file; restore with `u`.
- Export to quickfix or the argument list, open all matched files, and
  batch-replace matched lines.
- Persistent search history.
- Configurable keymaps. No default key mappings are defined.
- `.git` is excluded by default; `rg` also respects `.gitignore`.

## Requirements

- Vim 8.2+ or Neovim 0.7+
- `rg` (preferred) or `grep` in `PATH`
- `rg` must support `--json` when used

## Installation

### vim-plug

```vim
Plug 'lyuangg/vim-rgrep'
```

### lazy.nvim / LazyVim

```lua
return {
  {
    "lyuangg/vim-rgrep",
    cmd = { "Rgrep", "RgrepWord", "RgrepLast", "RgrepHistory", "RgrepClose" },
  },
}
```

No `setup()` call is required.

### Manual

```sh
cp -r vim-rgrep ~/.vim/pack/plugins/start/vim-rgrep
```

Neovim:

```sh
cp -r vim-rgrep ~/.local/share/nvim/site/pack/plugins/start/vim-rgrep
```

## Usage

| Command | Action |
| --- | --- |
| `:Rgrep [pattern] [dir]` | Search; prompts for the pattern when omitted |
| `:Rgrep! [pattern] [dir]` | Literal search |
| `:RgrepWord [dir]` | Search the word under the cursor as a literal |
| `:RgrepLast` | Re-run the most recent search |
| `:RgrepHistory` | Select from saved searches |
| `:RgrepRefresh` | Re-run the current search, keeping filters |
| `:RgrepInfo` | Show the engine, root, pattern, counts, and command |
| `:RgrepQF` / `:RgrepQF!` | Set the quickfix list; `!` also opens it |
| `:RgrepArgs` | Set the argument list to the matched files |
| `:RgrepOpenAll` | Open all matched files (respects `g:rgrep_open_mode`) |
| `:RgrepReplace` | Replace on the currently shown result lines |
| `:RgrepClose` | Close the search tab |

The last argument of `:Rgrep` is treated as the search path when it looks like
a directory; otherwise it remains part of the pattern. Quote patterns that
contain spaces when the last word could be a directory.

```vim
:Rgrep TODO
:Rgrep 'TODO|FIXME' ~/project/src
:Rgrep! foo.bar
:RgrepWord ~/project/src
:Rgrep TODO .              " search the current directory explicitly
```

## Keymaps

### Result list

| Key | Action |
| --- | --- |
| `j` / `k` | Move between hits; the preview follows |
| `gg` / `G` | First / last hit |
| `Ctrl-d` / `Ctrl-u` | Move half a page |
| `<CR>` / `o` | Open the hit |
| `d` | Remove the hit from the results |
| `D` | Remove all hits of the current file |
| `u` | Restore the last removed hit or file group |
| `f` | Add an AND filter; `!pattern` excludes |
| `F` | Clear all filters |
| `p` | Show / hide the preview |
| `]f` / `[f` | Next / previous file |
| `s` | New search; accepts `pattern [dir]` |
| `r` | Re-run the current search |
| `H` | Select a previous search |
| `Q` | Send results to quickfix and open it |
| `q` | Close the search tab |
| `/` | Vim search inside the results |

### Preview

| Key | Action |
| --- | --- |
| `<CR>` / `o` | Open the previewed file |
| `s` | New search |
| `f` | Add a filter |
| `q` | Close the search tab |

### Customization

```vim
let g:rgrep_keymaps = {
  \ 'open_file': '<CR>',
  \ 'open_file_tab': 'o',
  \ 'quit': 'q',
  \ 'search': 's',
  \ 'filter': 'f',
  \ 'delete': 'd',
  \ 'delete_file': 'D',
  \ 'history': 'H',
  \ }

let g:rgrep_keymaps_enabled = 0   " disable all plugin keymaps
```

A key can be a string or a list of strings; an empty string disables it.
Available actions: `open_file`, `open_file_tab`, `quit`, `toggle_preview`,
`hide_preview`, `delete`, `delete_file`, `restore`, `filter`, `clear_filter`,
`refresh`, `search`, `quickfix`, `next_file`, `prev_file`, `history`.

Global mappings can use `<Plug>(rgrep)` and `<Plug>(rgrep-word)`.

## Configuration

| Option | Default | Description |
| --- | --- | --- |
| `g:rgrep_engine` | `'auto'` | `'auto'`, `'rg'`, or `'grep'` |
| `g:rgrep_bin` | `'rg'` | ripgrep executable |
| `g:rgrep_grep_bin` | `'grep'` | grep executable used by the fallback |
| `g:rgrep_root` | `''` | Default search root; empty means the current directory |
| `g:rgrep_case` | `'smart'` | `'smart'`, `'ignore'`, or `'sensitive'` |
| `g:rgrep_exclude_git` | `1` | Exclude `.git` |
| `g:rgrep_globs` | `[]` | Extra globs; `!` excludes |
| `g:rgrep_rg_args` | `[]` | Extra `rg` arguments (rg only) |
| `g:rgrep_max_results` | `10000` | Total result limit; `0` is unlimited |
| `g:rgrep_max_columns` | `500` | `rg --max-columns` |
| `g:rgrep_max_filesize` | `'5M'` | `rg --max-filesize` |
| `g:rgrep_sync` | `0` | Run synchronously (diagnostics) |
| `g:rgrep_layout` | `'bottom'` | `'bottom'`, `'top'`, `'left'`, `'right'` |
| `g:rgrep_height` | `0` | Result list height; `0` is automatic |
| `g:rgrep_width` | `0` | Result list width; `0` is automatic |
| `g:rgrep_preview` | `1` | Show the preview pane |
| `g:rgrep_open_mode` | `'tab'` | `'tab'` or `'shared'` |
| `g:rgrep_preview_wrap` | `0` | Wrap long preview lines |
| `g:rgrep_preview_max_bytes` | `2097152` | Full-preview size limit |
| `g:rgrep_preview_full_lines` | `3000` | Full-preview line limit |
| `g:rgrep_preview_context` | `150` | Context lines in chunked previews |
| `g:rgrep_preview_debounce_ms` | `30` | Preview update debounce |
| `g:rgrep_render_ms` | `50` | Result redraw throttle |
| `g:rgrep_statusline` | `1` | Custom result statusline |
| `g:rgrep_filetypes` | `{}` | Preview filetype overrides |
| `g:rgrep_open_all_limit` | `10` | Confirmation threshold for `RgrepOpenAll` |
| `g:rgrep_replace_confirm` | `1` | Confirm before `RgrepReplace` |
| `g:rgrep_history_file` | `'~/.rgrep_history'` | Search history file |
| `g:rgrep_history_size` | `50` | Number of saved searches; `0` disables |
| `g:rgrep_keymaps_enabled` | `1` | Enable plugin keymaps |
| `g:rgrep_keymaps` | `{}` | Keymap overrides |

## Notes

- Filters and `RgrepReplace` use Vim regular expressions, not the search
  engine's regex syntax.
- The `grep` fallback uses `grep -E` (or `-F` for literal searches) and does
  not honor `.gitignore`. Rust-specific constructs such as `\d` and lookarounds
  are unavailable. `g:rgrep_rg_args`, `g:rgrep_max_columns`, and
  `g:rgrep_max_filesize` do not apply; globs map to `--include`, `--exclude`,
  and `--exclude-dir`; match columns are best-effort.
- `RgrepReplace` replaces all occurrences on the shown result lines, refuses
  to run when a target buffer is modified, and leaves a quickfix list.
- With `g:rgrep_open_mode = 'shared'`, opened files remain as buffers in one
  dedicated tab. Use `:bnext`, `:bprev`, `:ls`, or `:buffer` to switch.
- Search history stores the pattern, search root, and literal flag. It does not
  store results; selecting an entry re-runs the search.
- With `laststatus=1` and the preview hidden, the result statusline is not
  visible; set `laststatus=2` if required.
- `let g:rgrep_debug = 1` appends raw search output to `~/.rgrep.log`.
