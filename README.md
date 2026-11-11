# ave

把 Neovim 和原生 Coding Agent（Claude Code / Codex / Pi）接在一起，让 Agent 能直接驱动编辑器：跳到实现、高亮代码范围、串起跨文件的探索路径。

左侧是编辑器，右侧是 Agent 自己的 TUI（不重写 Chat UI），中间一条本机 socket 做双向通道。

```
nvim ── UDS(JSON-RPC/NDJSON) ── node bridge-helper ── MCP(stdio) ── claude / codex / pi
```

## 状态

`0.1.0`：骨架通了。布局 + 终端 + 桥 + `editor_context` / `editor_open` / `editor_highlight`，三个 Agent 的接入壳都有；探索路径栈、LSP 工具、被动跟随未做。

## 安装

需要 Neovim ≥ 0.10、Node ≥ 20（三个 Agent 本身就带 Node）。

```lua
-- lazy.nvim
{
  "wii/ave",
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
```

默认键位（可在 `setup()` 里覆盖）：`<leader>aa` 开关面板。

Agent 侧无需手动配置，`ave` 会按 Agent 自己的方式注册 MCP server（见 [docs/agents.md](docs/agents.md)）。

## 文档

- [docs/architecture.md](docs/architecture.md) — 结构、协议、状态归属
- [docs/agents.md](docs/agents.md) — 三个 Agent 的接入差异（实测）

## 设计取舍

- 不实现自己的 Chat UI，右侧就是 Agent 的终端。
- 不暴露任意 Lua 执行，桥只认白名单方法。
- Agent 提供的行号视为可能过期：优先用 `snippet` 兜底定位。
