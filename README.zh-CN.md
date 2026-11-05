# vim-rgrep

Vim/Neovim 的递归搜索插件。使用 ripgrep（`rg`）或 `grep` 搜索，在独立标签页中
显示结果和实时预览，打开文件时不影响结果页面。

[English](README.md)

## 功能

- 从指定目录递归搜索关键字或正则。
- 优先使用 `rg`，不可用时回退到 `grep`。
- 结果和预览位于独立标签页。结果列表可放在底部、顶部、左侧或右侧，预览位于相反方向。
- 移动选择时预览同步更新；`<CR>` 打开选中文件。
- 文件可按“每个文件一个标签页”或“共享一个标签页”打开（`g:rgrep_open_mode`）。
- 支持多个 AND 过滤条件及排除条件（`!pattern`）。
- 支持导出到 quickfix 或参数列表、打开全部匹配文件、批量替换匹配行。
- 支持持久化搜索历史。
- 快捷键可配置，默认不定义按键映射。
- 默认排除 `.git`；使用 `rg` 时同时遵循 `.gitignore`。

## 要求

- Vim 8.2+ 或 Neovim 0.7+
- `PATH` 中有 `rg`（优先）或 `grep`
- 使用 `rg` 时需支持 `--json`

## 安装

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

无需调用 `setup()`。

### 手动安装

```sh
cp -r vim-rgrep ~/.vim/pack/plugins/start/vim-rgrep
```

Neovim：

```sh
cp -r vim-rgrep ~/.local/share/nvim/site/pack/plugins/start/vim-rgrep
```

## 使用

| 命令 | 说明 |
| --- | --- |
| `:Rgrep [pattern] [dir]` | 搜索；省略 pattern 时提示输入 |
| `:Rgrep! [pattern] [dir]` | 字面量搜索 |
| `:RgrepWord [dir]` | 按字面量搜索光标下的单词 |
| `:RgrepLast` | 重跑最近一次搜索 |
| `:RgrepHistory` | 从搜索历史中选择 |
| `:RgrepRefresh` | 重跑当前搜索，保留过滤条件 |
| `:RgrepInfo` | 显示引擎、根目录、pattern、数量和实际命令 |
| `:RgrepQF` / `:RgrepQF!` | 写入 quickfix；`!` 同时打开窗口 |
| `:RgrepArgs` | 将匹配文件写入参数列表 |
| `:RgrepOpenAll` | 打开全部匹配文件（遵循 `g:rgrep_open_mode`） |
| `:RgrepReplace` | 替换当前显示的结果行 |
| `:RgrepClose` | 关闭搜索标签页 |

`:Rgrep` 的最后一个参数在看起来是目录时作为搜索路径，否则并入 pattern。
pattern 含空格且最后一个词可能是目录时，建议加引号。

```vim
:Rgrep TODO
:Rgrep 'TODO|FIXME' ~/project/src
:Rgrep! foo.bar
:RgrepWord ~/project/src
:Rgrep TODO .              " 显式搜索当前目录
```

## 快捷键

### 结果列表

| 按键 | 动作 |
| --- | --- |
| `j` / `k` | 上下移动，预览跟随 |
| `gg` / `G` | 第一条 / 最后一条 |
| `Ctrl-d` / `Ctrl-u` | 半页移动 |
| `<CR>` / `o` | 打开当前结果 |
| `d` | 从结果中删除当前条 |
| visual 选中 + `d` | 删除全部选中结果，可用 `u` 一次恢复 |
| `D` | 删除当前文件的全部结果 |
| `u` | 恢复上一次删除的条目或文件组 |
| `f` | 追加 AND 过滤条件；`!pattern` 表示排除 |
| `F` | 清除全部过滤条件 |
| `p` | 显示 / 隐藏预览 |
| `]f` / `[f` | 下一个 / 上一个文件 |
| `s` | 新搜索；支持 `pattern [dir]` |
| `r` | 重跑当前搜索 |
| `H` | 选择搜索历史 |
| `Q` | 结果写入 quickfix 并打开 |
| `?` | 显示 / 隐藏快捷键帮助面板 |
| `q` | 关闭搜索标签页 |
| `/` | 在结果中执行 Vim 搜索 |

### 预览窗口

| 按键 | 动作 |
| --- | --- |
| `<CR>` / `o` | 打开当前预览的文件 |
| `s` | 新搜索 |
| `f` | 追加过滤条件 |
| `?` | 显示 / 隐藏快捷键帮助面板 |
| `q` | 关闭搜索标签页 |

### 自定义

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
  \ 'help': '?',
  \ }

let g:rgrep_keymaps_enabled = 0   " 禁用全部插件快捷键
```

键值可以是字符串或字符串列表；设为空字符串表示禁用。可用动作：
`open_file`、`open_file_tab`、`quit`、`toggle_preview`、`hide_preview`、
`delete`、`delete_file`、`restore`、`filter`、`clear_filter`、`refresh`、
`search`、`quickfix`、`next_file`、`prev_file`、`history`、`help`。

全局映射可使用 `<Plug>(rgrep)` 和 `<Plug>(rgrep-word)`。

## 配置

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `g:rgrep_engine` | `'auto'` | `'auto'`、`'rg'` 或 `'grep'` |
| `g:rgrep_bin` | `'rg'` | ripgrep 可执行文件 |
| `g:rgrep_grep_bin` | `'grep'` | 回退时使用的 grep 可执行文件 |
| `g:rgrep_root` | `''` | 默认搜索根目录；空表示当前目录 |
| `g:rgrep_case` | `'smart'` | `'smart'`、`'ignore'` 或 `'sensitive'` |
| `g:rgrep_exclude_git` | `1` | 排除 `.git` |
| `g:rgrep_globs` | `[]` | 额外 glob；`!` 表示排除 |
| `g:rgrep_rg_args` | `[]` | 传给 `rg` 的额外参数（仅 rg） |
| `g:rgrep_max_results` | `10000` | 结果总数上限；`0` 表示不限制 |
| `g:rgrep_max_columns` | `500` | `rg --max-columns` |
| `g:rgrep_max_filesize` | `'5M'` | `rg --max-filesize` |
| `g:rgrep_sync` | `0` | 同步执行（用于诊断） |
| `g:rgrep_layout` | `'bottom'` | `'bottom'`、`'top'`、`'left'`、`'right'` |
| `g:rgrep_height` | `0` | 结果列表高度；`0` 表示自动 |
| `g:rgrep_width` | `0` | 结果列表宽度；`0` 表示自动 |
| `g:rgrep_preview` | `1` | 显示预览 |
| `g:rgrep_open_mode` | `'tab'` | `'tab'` 或 `'shared'` |
| `g:rgrep_preview_wrap` | `0` | 预览是否折行 |
| `g:rgrep_preview_max_bytes` | `2097152` | 完整预览的大小上限 |
| `g:rgrep_preview_full_lines` | `3000` | 完整预览的行数上限 |
| `g:rgrep_preview_context` | `150` | 分段预览的上下文行数 |
| `g:rgrep_preview_debounce_ms` | `30` | 预览更新防抖 |
| `g:rgrep_render_ms` | `50` | 结果重绘节流 |
| `g:rgrep_statusline` | `1` | 结果状态栏（数量、过滤条件和帮助提示） |
| `g:rgrep_filetypes` | `{}` | 预览文件类型覆盖 |
| `g:rgrep_open_all_limit` | `10` | `RgrepOpenAll` 的确认阈值 |
| `g:rgrep_replace_confirm` | `1` | `RgrepReplace` 执行前确认 |
| `g:rgrep_history_file` | `'~/.rgrep_history'` | 搜索历史文件 |
| `g:rgrep_history_size` | `50` | 保存的搜索数量；`0` 表示禁用 |
| `g:rgrep_keymaps_enabled` | `1` | 启用插件快捷键 |
| `g:rgrep_keymaps` | `{}` | 快捷键覆盖 |

## 说明

- 过滤和 `RgrepReplace` 使用 Vim 正则，不使用搜索引的正则语法。
- `grep` 回退使用 `grep -E`（字面量搜索使用 `-F`），且不遵循 `.gitignore`。
  `rg` 的 Rust 正则特性（如 `\d`、环视）不可用；`g:rgrep_rg_args`、
  `g:rgrep_max_columns`、`g:rgrep_max_filesize` 不生效；glob 会映射为
  `--include`、`--exclude`、`--exclude-dir`；匹配列号为尽力估算。
- `RgrepReplace` 替换当前显示结果行中的全部匹配；目标 buffer 有未保存修改时
  拒绝执行；执行后保留 quickfix 列表。
- `g:rgrep_open_mode = 'shared'` 时，打开的文件保留在一个专用标签页的 buffer
  列表中，可用 `:bnext`、`:bprev`、`:ls`、`:buffer` 切换。
- 搜索历史保存 pattern、根目录和字面量标记，不保存结果；选择后会重新搜索。
- `laststatus=1` 且预览隐藏时，结果状态栏不可见；需要时设置 `laststatus=2`。
- `let g:rgrep_debug = 1` 会把原始搜索输出追加到 `~/.rgrep.log`。
