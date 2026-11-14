# Agent 接入

三个 Agent 的 MCP 接入方式不同，不要指望一个配置文件通吃。以下是本机实测结论
（claude 2.1.319 / codex 0.166.0 / pi 1.5.0 / nvim 0.12.5）。

| Agent | MCP 子进程继承 `$WORKBENCH_SOCKET` | 注册方式 | 注意 |
|---|---|---|---|
| claude | 是 | `--mcp-config <file> --strict-mcp-config` | 目录未信任时不建 session，也就不起 MCP；表现为「MCP 没连上」 |
| codex | **否**（子进程里环境变量被过滤） | `-c 'mcp_servers.ave.env={WORKBENCH_SOCKET="..."}'` | 每 Session 走命令行参数，不写文件 |
| pi | 是 | 用户级 `~/.pi/agent/mcp.json` | 默认 `exposure: "codemode"`，工具不会直接声明给模型，必须写 `"exposure": "direct"` |

## claude

`ave` 在 `stdpath("cache")/ave/session-<id>/mcp.json` 写：

```json
{"mcpServers":{"ave":{"command":"node","args":["<helper>","mcp"]}}}
```

启动命令加 `--mcp-config <该文件> --strict-mcp-config`，避免和其他来源的 MCP 混在一起。

不写 `settings.json`，也不注册 `PostToolUse` hook。普通文件读写只服务于 Agent 自己的任务，
不会自动让编辑器跳转；需要展示时由 Agent 主动调用 `editor_open` 或 `editor_tour`。

## codex

不写文件，直接命令行覆盖（值按 TOML 解析）：

```
codex -c 'mcp_servers.ave.command="node"'
      -c 'mcp_servers.ave.args=["<helper>","mcp"]'
      -c 'mcp_servers.ave.env={WORKBENCH_SOCKET="/run/user/<uid>/ave/4242.sock"}'
```

`codex mcp list` 只验证配置解析、不连接、不 spawn，不能当连通性探针。真实验证用：

```
codex -c ... exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox '<prompt>'
```

实测 `editor_context` 调用成功，回包是工作区根。stdio 握手时 codex 会打一条
`rmcp::transport::worker ... Unexpected content type` 的 ERROR，但工具调用正常，可忽略。

codex 不注册 hook；需要展示时由 Agent 主动调用 `editor_open` 或 `editor_tour`。

## pi

用户级配置只写一次（`:Ave install pi`），之后所有 Session 共用：

```json
{"mcpServers":{"ave":{"command":"node","args":["<helper>","mcp"],"exposure":"direct"}}}
```

不加 `exposure: "direct"` 时 pi 启动会提示 `MCP tools are only reachable from the codemode or
tool_search tool`，工具对模型不可见。项目级 `.pi/mcp.json` 需要项目信任，不用它。

## 通用

- `WORKBENCH_SOCKET` 由 `:terminal` 子进程继承（`$NVIM` 也可用，但 codex 会过滤，别拿它做路由）。
- Agent 退出后 helper 随之退出；nvim 侧对 socket 上无连接不做事。
- 无法向 Agent 的 TUI 注入「结构化消息」。需要把选区送给 Agent 时，走 `chansend` 粘贴
  `@path:Lx-Ly` 文本（仅用户主动触发，不自动提交）。

## 工具可见性与触发边界

实测（claude 2.1.32x）：即使 `--mcp-config` 已接上，ave 的工具也只是以名字出现在
`deferred tools` 列表里，schema 没进上下文，需要模型用 `ToolSearch` 加载。
同时 user skill（如 `code-explore`）的输出模板可能覆盖 MCP `instructions`，所以触发边界不能只写在
工具描述里。

三个 adapter 都注入 `lua/ave/agent/adapters/init.lua` 的 `M.directive`：默认只在聊天中回答，
普通文件读写和跨文件分析不自动操作编辑器；有明确或较强的展示需求时才调用 `editor_open` /
`editor_tour`，用户明确禁止时优先遵守。

claude 额外通过 `--append-system-prompt` 指明：只有确需调用某个 ave 工具时才用 `ToolSearch`
加载对应工具，否则不加载。codex 使用 `-c 'developer_instructions="…"'`，pi 使用
`--append-system-prompt`；三者的触发规则保持一致。
