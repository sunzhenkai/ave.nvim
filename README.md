# ave

中文（默认）· [English](README.en.md)

把 Neovim 和原生 Coding Agent（Claude Code / Codex / Pi）接在一起，让 Agent 能直接驱动编辑器：跳到实现、高亮代码范围、串起跨文件的探索路径。

左侧是编辑器，右侧是 Agent 自己的 TUI（不重写 Chat UI），中间一条本机 socket 做双向通道。

```
nvim ── UDS(JSON-RPC/NDJSON) ── node bridge-helper ── MCP(stdio) ── claude / codex / pi
```

## 状态

`0.1.0`：布局 + 终端 + 桥 + `editor_context` / `editor_open` / `editor_highlight` / `explore_path` / `editor_lsp` / `editor_tour`，三个 Agent 的接入壳都有。

- 探索路径栈可用，按工作区落盘（`stdpath("state")/ave/path-<hash>.json`），重开 nvim 能接着走。
- Claude Code 有被动跟随（`PostToolUse` hook 把自己的读写自动压进路径），不依赖 Agent 主动调工具。
- 业务导览（tour）：Agent 一次给出排好序的跳转块（文件 + 行范围 + 解释），人按块往前走，`3<leader>ag` 直达第 3 块。
- Codex 只走主动工具调用；Pi 需要 `:Ave install pi`，且没有被动通道。

## 安装

需要 Neovim ≥ 0.10、Node ≥ 20（三个 Agent 本身就带 Node）。

```lua
-- lazy.nvim
{
  "sunzhenkai/ave.nvim",
  dependencies = {},
  config = function() require("ave").setup() end,
}
```

首次使用先装 helper 依赖：

```vim
:Ave install          " 在 plugin 目录执行 npm ci
:Ave install pi       " 给 Pi 写用户级 MCP 配置（~/.pi/agent/mcp.json）
```

Claude Code 和 Codex 不需要装到全局：`ave` 用 `--mcp-config` / `-c` 参数临时注入。Pi 只认用户级配置，所以要显式跑一次 `:Ave install pi`。

### LazyVim

LazyVim 只是 lazy.nvim 的预设，插件丢进 `lua/plugins/` 就会被自动导入，不需要额外的键位或 `opts` 桥接：

```lua
-- ~/.config/nvim/lua/plugins/ave.lua
return {
  "sunzhenkai/ave.nvim",
  config = function() require("ave").setup() end,
}
```

唯一要注意的是 LazyVim 的 AI 类 extra（`extras/ai/claudecode`、`sidekick`、`copilot-chat`）
把 `<leader>a` 占成了 AI 组，其中的 `<leader>aa` / `<leader>as` 会跟 ave 撞。要么不装那些 extra，
要么改 key（只写要改的，其余的保持默认）：

```lua
require("ave").setup({ keys = { toggle = "<leader>cA", send = "<leader>cS" } })
```

`<leader>` 本身跟着 LazyVim（默认空格）走，ave 不接管。

## 用法

```vim
:Ave pick             " 浮窗选 agent 后启动（<leader>aa 就是它）
:Ave open             " 直接开默认 agent（默认 claude）
:Ave open codex       " 指定 agent
:Ave close
:Ave toggle           " 开着就关，没开就按默认 agent 起
:Ave stop             " 结束当前 agent 进程
:Ave status           " 看 helper / socket / 会话状态
:Ave back             " 沿探索路径后退一步
:Ave forward          " 前进一步
:Ave path             " 路径扔进 loclist，可跳选
:Ave full             " 面板全屏 / 退出全屏
:Ave tour             " 重开当前业务导览的块列表
:Ave tour off         " 收起导览
:Ave goto 3           " 跳到导览第 3 块
```

默认键位（`setup()` 时就装好，不需要先 `:Ave`；可在 `setup()` 里覆盖）：

| 键 | 动作 |
|---|---|
| `<leader>aa` | 打开 agent 选择浮窗，选完启动并把光标交给它 |
| `<leader>a[` | 路径后退 |
| `<leader>a]` | 路径前进 |
| `<leader>al` | 路径 loclist |
| `<leader>aF` | 面板全屏（独立 tab，原分屏布局不动） |
| `<leader>ag` | 导览下一块；`3<leader>ag` 直达第 3 块（无计数时提示输入） |
| `<leader>as` | 把当前选区（或光标行）以 `@file:Lx-Ly` 送进 Agent 终端 |
| `Esc`（面板内） | 原样送给 Agent（打断/取消），插件不拦截 |
| `Ctrl-\ Ctrl-N`（面板内） | 回到 normal mode |
| `Ctrl-h/j/k/l`（面板内） | 直接跨窗口，不用先退 terminal-mode |
| `i` / `a`（面板 normal） | 回到 Agent 输入 |

导览（tour）和探索路径（path）是两件事：path 是全自动压栈的历史（含 Claude 的被动跟随），
tour 是 Agent 先问过你、再一次性推送的线性脚本。导览激活时 `<leader>a[` / `<leader>a]` 走导览，否则走路径。

Agent 侧无需手动配置，`ave` 会按 Agent 自己的方式注册 MCP server（见 [docs/agents.md](docs/agents.md)）。

面板里的 `Esc` 不给 Neovim 抢：Agent 靠它中断任务。要挪窗口按 `Ctrl-h/j/k/l`，
要进 normal mode 按 `Ctrl-\ Ctrl-N`。真想要双击 `Esc` 的老行为，就开 `esc_double = true`
（代价是第一下已经发给 Agent 了，打断还是会先发生）。

## 配置

`agents.<name>.cmd` 就是整条启动命令，ave 只往后面追加自己需要的参数（MCP 配置、system prompt），
所以 agent 自己的 flag 直接写进去就行。两个常用的提权开关：

```lua
require("ave").setup({
  agents = {
    claude = { cmd = { "claude", "--permission-mode", "bypassPermissions" } },
    codex = { cmd = { "codex", "--dangerously-bypass-approvals-and-sandbox" } },
  },
})
```

只写其中一个也行，没写到的 agent 保留默认命令。这两个开关都跳过 agent 的确认（codex 还关掉
沙箱），只在你信任的仓库里开。

其它选项：`agent`（默认启动哪个）、`width`、`focus_on_open`、`esc_double`、`node`、`helper`、
`socket_dir`、`keys`，见 `lua/ave/config.lua` 的 `M.defaults`。`agents` 和 `keys` 都按条目合并，
只写你要改的那几个。

## 测试

```bash
bash tests/run.sh
```

两段：`tests/e2e.lua`（纯 lua，路径栈/跳转/协议）和 `bridge-helper/test/e2e.mjs`（走真 MCP：
`editor_context` → helper → UDS → nvim）。第二段会起一个真 nvim（`tests/host.lua`，需要带 UI 的终端，
headless 下 UDS 回包会拖到 `vim.wait` 结束）和 clangd（LSP 用），缺了会失败。

## 许可证

[MIT](LICENSE)

## 文档

- [docs/architecture.md](docs/architecture.md) — 结构、协议、状态归属
- [docs/agents.md](docs/agents.md) — 三个 Agent 的接入差异（实测）

## 设计取舍

- 不实现自己的 Chat UI，右侧就是 Agent 的终端。
- 不暴露任意 Lua 执行，桥只认白名单方法。
- Agent 提供的行号视为可能过期：优先用 `snippet` 兜底定位。
