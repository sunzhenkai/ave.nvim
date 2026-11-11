# 架构

## 组件

| 组件 | 位置 | 职责 |
|---|---|---|
| plugin host | `lua/ave/` | 布局、会话、命令、键位 |
| bridge server | `lua/ave/bridge/server.lua` | nvim 内 UDS 服务，NDJSON + JSON-RPC 2.0 |
| router | `lua/ave/bridge/router.lua` | 方法白名单 → handler |
| editor | `lua/ave/editor/state.lua` | 工作窗口判定、定位、高亮 |
| helper | `bridge-helper/index.mjs` | MCP stdio server + 一次性 `call` |

## 连接与路由

一个 nvim 实例一个 socket：`$XDG_RUNTIME_DIR/ave/<pid>.sock`（无 XDG 时 `/tmp/ave-<uid>/`，
目录 0700、socket 0600）。

每个 Session 的环境变量决定它连谁：

```
WORKBENCH_SOCKET=/run/user/1000/ave/4242.sock
AVE_SESSION=1
AVE_ROOT=/path/to/repo
```

Agent 由 nvim 的终端启动，环境变量随进程继承；helper 从自身环境读取，所以 MCP 配置是静态的，
不需要每 Session 生成一份。唯一例外是 Codex：它会过滤 MCP 子进程的环境变量，必须显式传（见 `docs/agents.md`）。

## 协议

NDJSON，一行一条 JSON-RPC 2.0 消息。请求带 `params.session`，便于将来在同一 socket 上区分会话。

```json
{"jsonrpc":"2.0","id":"1","method":"editor.open","params":{"session":"1","file":"lua/ave/init.lua","line":12}}
{"jsonrpc":"2.0","id":"1","result":{"ok":true,"file":"/abs/lua/ave/init.lua","line":12}}
```

方法白名单（`bridge/router.lua`）：`ping`、`editor.context`、`editor.open`、`editor.highlight`。
不存在 method 通配、没有 `nvim_exec_lua` 入口。

## 实现约束（踩过的）

1. **luv 回调是 fast event context。** `read_start` 里调 `vim.api` / `vim.fn` 会 `E5560`。
   读回调只做拼包、解帧、`vim.schedule` 派发，所有编辑器操作在主循环执行。
2. **socket 默认权限 0755**，同机其他用户可连，必须显式 `fs_chmod(0o600)`。
3. **UDS 路径上限 108 字节**，别塞深目录。
4. **跳转不能抢焦点。** `editor.open` 默认 `focus=false`：在工作窗口换 buffer、设光标；用户在 Agent
   输入框打字时不会被抢走。要真跳过去才传 `focus=true`。
5. **高亮用 extmark namespace**，不用 `matchadd`（切 buffer 就没了）。

## 状态归属

nvim 独占所有状态：Session 表、工作窗口、高亮 namespace、探索路径。Helper 无状态，Agent 无状态。
持久化只写 `stdpath("state")/ave/` 下的 JSON，退出时落盘。
