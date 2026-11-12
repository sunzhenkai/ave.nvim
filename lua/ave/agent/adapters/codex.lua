-- Codex：-c 覆盖是 TOML，且不会把 env 透给 MCP 子进程，必须显式写进 env 表
local M = {}

function M.spec(sess, cfg)
  -- shortcut: 路径含双引号会破坏 TOML 内联表，按无特殊字符处理
  local args = {
    "-c",
    'mcp_servers.ave.command="' .. cfg.node .. '"',
    "-c",
    'mcp_servers.ave.args=["' .. cfg.helper .. '","mcp"]',
    "-c",
    'mcp_servers.ave.env={WORKBENCH_SOCKET="' .. sess.socket .. '"}',
    -- codex 没有 append-system-prompt，用 developer_instructions 追加开发者消息
    "-c",
    'developer_instructions="' .. require("ave.agent.adapters").directive .. '"',
  }
  local cmd = vim.deepcopy(cfg.agents.codex.cmd)
  vim.list_extend(cmd, args)
  return { cmd = cmd, cwd = sess.root }
end

return M
