# 架构

## 组件

| 组件 | 位置 | 职责 |
|---|---|---|
| plugin host | `lua/ave/` | 布局、会话、命令、键位 |
| bridge server | `lua/ave/bridge/server.lua` | nvim 内 UDS 服务，NDJSON + JSON-RPC 2.0 |
| router | `lua/ave/bridge/router.lua` | 方法白名单 → handler |
| editor | `lua/ave/editor/init.lua` | 定位、snippet 兜底、高亮、LSP 查询 |
| helper | `bridge-helper/index.mjs` | MCP stdio server + 一次性 `call` |
| tour | `lua/ave/tour/init.lua` | 业务导览：块列表（loclist）、解释（virt_lines）、按块前进 |

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

agent 不是从 nvim 启动时（比如直接在终端跑 `pi`）没有 `WORKBENCH_SOCKET`：helper 会扫
`$XDG_RUNTIME_DIR/ave/*.sock`，用 `editor.context` 探活，优先挑 `root` 与自身 cwd 相同的实例；
只有一个活实例时直接用它，多个都对不上就报错而不是猜。

## 协议

NDJSON，一行一条 JSON-RPC 2.0 消息。请求带 `params.session`，便于将来在同一 socket 上区分会话。

```json
{"jsonrpc":"2.0","id":"1","method":"editor.open","params":{"session":"1","file":"lua/ave/init.lua","line":12}}
{"jsonrpc":"2.0","id":"1","result":{"ok":true,"file":"/abs/lua/ave/init.lua","line":12}}
```

方法白名单（`bridge/router.lua`）：`ping`、`editor.context`、`editor.open`、`editor.highlight`、
`editor.lsp`、`explore.path`、`explore.back`、`explore.forward`、
`tour.set`、`tour.next`、`tour.prev`、`tour.goto`、`tour.clear`。
不存在 method 通配、没有 `nvim_exec_lua` 入口。

## 实现约束（踩过的）

1. **luv 回调是 fast event context。** `read_start` 里调 `vim.api` / `vim.fn` 会 `E5560`。
   读回调只做拼包、解帧、`vim.schedule` 派发，所有编辑器操作在主循环执行。
2. **socket 默认权限 0755**，同机其他用户可连，必须显式 `fs_chmod(0o600)`。
3. **UDS 路径上限 108 字节**，别塞深目录。
4. **跳转不能抢焦点。** `editor.open` 默认 `focus=false`：在工作窗口换 buffer、设光标；用户在 Agent
   输入框打字时不会被抢走。要真跳过去才传 `focus=true`。
5. **遗留 swap 文件会让 `bufload` 弹模态框**，agent 的跳转一旦命中就卡住整个桥。`editor.open`
   期间置 `M.navigating`，`SwapExists` autocmd 里据此把 `v:swapchoice` 设成 `e`（照常打开，不动 swap）。
6. **terminal-mode 的 `Esc` 归 Agent。** 面板 buffer 上 `t` 模式映射 `<Esc>`：单击 `chansend` 把字节
   原样送进 Agent 的 pty，300ms 内第二击才发 `<C-\><C-n>` 回 normal。直接映射成 `<C-\><C-n>` 会让
   Agent 的取消键失效。normal mode 里再映射 `i`/`a` 到 `:startinsert`，否则回到面板里打不了字。
7. **高亮用 extmark namespace**，不用 `matchadd`（切 buffer 就没了）。

## 探索路径

`lua/ave/explore/init.lua` 是一个栈，不是图：每次 `editor.open`（非路径回放）压一项
`{file, line, end_line, title}`，`back` / `forward` 只移动指针并按记录重放跳转。

- 同一位置连续打开不重复压栈。
- 后退后再从 agent 打开新位置，会丢弃指针之后的分支（和浏览器后退后重新点击一致）。
- `:Ave path` 把栈灌进 loclist，只读视图，不写文件。
- 栈按工作区落盘：`stdpath("state")/ave/path-<sha256(root) 前 16 位>.json`，退出时保存、起桥后读回。
  同行同文件不重复、位置和标题都存，重开 nvim 接着走。

## 代码智能

`editor_lsp`（`lua/ave/editor/init.lua` 的 `M.lsp`）不自己解析代码，全部转发给 Neovim 的 LSP client：

- `kind`：`definition` / `references` / `symbols` / `implementations`，映射到对应 LSP 方法。
- 返回统一成 `{file, line, column, end_line}`（Definition/LocationLink/DocumentSymbol 三种形状都收），
  最多 50 条，超出打 `truncated`。
- 目标文件没挂 client 时（agent 报的文件可能用户从没打开过），退回当前 buffer 的 client——
  LSP 请求按 URI 定位文档，server 照常能查；缺 filetype 就补 `vim.filetype.match`，缺 client 就
  `vim.lsp.buf_attach_client`（否则 server 没收到 didOpen，`references` 会返回空）。
- 没有 client 就明确报错让 Agent 退回 grep，不静默返回空列表。

pyright 有个坑：nvim 0.12 + pyright 1.1.401 下 `initialize`/`initialized`/`didOpen` 都正常，但 server
发起 `textDocument/diagnostic` 后再无响应，之后所有请求（包括 `buf_request` 发出的）全部超时。
所以测试用 clangd 做 LSP 端到端，不在项目里做绕过。

## 主动触发

所有可见编辑器操作都由 Agent 主动调用 MCP 工具产生；普通 `Read` / `Edit` / `Write` 不注册
被动跟随 hook，也不会自动发 `editor.open`。

触发边界随各 Agent 的高优先级提示词和 MCP instructions 注入：`editor_open` 用于明确的打开、
跳转、跟随需求，或明显需要结合编辑器当前位置、选区、代码视图的任务；`editor_tour` 用于走读需求，
或明显适合按有序代码块阅读的跨文件流程。单纯解释、总结和普通跨文件分析不必然触发。
用户明确禁止使用 ave 或可见编辑器操作时，禁止规则优先。

## 全屏

`:Ave full`（`<leader>aF`）用 `:tab sbuffer <面板 buf>` 把面板搬进独立 tab，退出时 `:tabclose`。
选 tab 而不是「关掉其他窗口再重开」，是因为 tabclose 不会动原 tab 的分屏结构，代价为零；float
盖满全屏也能做，但要自己算尺寸、border 和各种 window option，还会遮住 statusline。
`M.close()` 在全屏状态下先关 tab 再删 buffer。

## 状态归属

nvim 独占所有状态：Session 表、工作窗口、高亮 namespace、探索路径。Helper 无状态，Agent 无状态。
路径栈按工作区落盘，Claude 的 `mcp.json` / `settings.json` 写在 `stdpath("cache")/ave/session-<id>/`，
退出时清目录。
