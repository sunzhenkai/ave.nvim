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

同一目录下还写 `settings.json` 带一个 `PostToolUse` hook，实现被动跟随：

```json
{"hooks":{"PostToolUse":[{"matcher":"Read|Edit|Write|MultiEdit|NotebookEdit",
  "hooks":[{"type":"command","command":"WORKBENCH_SOCKET='<sock>' node <helper> hook"}]}]}}
```

Agent 每次读/改文件，hook 从 stdin 拿 `tool_input.file_path`，推给编辑器跳转。实测：
`claude -p` 读两个文件后，路径栈里正好两项。hook 失败一律静默，不阻塞 Agent。

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

codex 没有 hook 机制，被动跟随做不了；只能等它的 JSONL 事件流或让 Agent 主动调 `editor_open`。

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

## claude：MCP 工具被 deferred，必须补 system prompt

实测（claude 2.1.32x）：即使 `--mcp-config` 已接上，ave 的工具也只是以名字出现在
`deferred tools` 列表里，schema 没进上下文，模型要主动 `ToolSearch` 才会加载。
同时 user skill（如 `code-explore`）的输出模板优先级高于 MCP `instructions`，
结果是它读完一堆文件、写一份长报告，一次 ave 工具都不调。

对策写在 adapter 里：启动时追加 `--append-system-prompt`（优先级高于 skill），
明确「先用 ToolSearch 加载 `mcp__ave__*`，再用一次 `editor_tour` 推代码块」。
`lua/ave/agent/adapters/claude.lua` 的 `M.directive` 就是这段文本。

验证：同一个「用 code-explore 梳理 editor_open 到高亮的链路」提示词——
不带该参数时工具调用只有 `Skill/Read/Bash`；带上后是
`Skill/Read/ToolSearch/editor_tour`。
