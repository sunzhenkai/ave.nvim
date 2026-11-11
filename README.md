# ave

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

## 用法

```vim
:Ave open             " 打开右侧 Agent 面板（默认 claude）
:Ave open codex       " 指定 agent
:Ave close
:Ave toggle
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

默认键位（可在 `setup()` 里覆盖）：

| 键 | 动作 |
|---|---|
| `<leader>aa` | 开关 Agent 面板 |
| `<leader>a[` | 路径后退 |
| `<leader>a]` | 路径前进 |
| `<leader>al` | 路径 loclist |
| `<leader>aF` | 面板全屏（独立 tab，原分屏布局不动） |
| `<leader>ag` | 导览下一块；`3<leader>ag` 直达第 3 块（无计数时提示输入） |
| `<leader>as` | 把当前选区（或光标行）以 `@file:Lx-Ly` 送进 Agent 终端 |
| `Esc Esc`（面板内） | 退出 terminal-mode 回 normal；单击 `Esc` 原样送给 Agent（它是 Agent 的取消键） |
| `i` / `a`（面板 normal） | 回到 Agent 输入 |

导览（tour）和探索路径（path）是两件事：path 是全自动压栈的历史（含 Claude 的被动跟随），
tour 是 Agent 先问过你、再一次性推送的线性脚本。导览激活时 `<leader>a[` / `<leader>a]` 走导览，否则走路径。

Agent 侧无需手动配置，`ave` 会按 Agent 自己的方式注册 MCP server（见 [docs/agents.md](docs/agents.md)）。

面板里的 `Esc` 不给 Neovim 抢：Agent 靠它中断任务。要挪窗口就在面板里按两次 `Esc`（300ms 内），
或者 `Ctrl-\ Ctrl-N`。不想要双击行为就把 `esc_double = false`。

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
