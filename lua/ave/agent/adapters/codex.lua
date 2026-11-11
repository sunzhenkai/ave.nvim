-- Codex：-c 覆盖是 TOML，且不会把 env 透给 MCP 子进程，必须显式写进 env 表
local M = {}

function M.spec(sess, cfg)
  local args = {
    "-c",
    'mcp_servers.ave.command="' .. cfg.node .. '"',
    "-c",
    'mcp_servers.ave.args=["' .. cfg.helper .. '","mcp"]',
    "-c",
    'mcp_servers.ave.env={WORKBENCH_SOCKET="' .. sess.socket .. '"}',
  }
  local cmd = vim.deepcopy(cfg.agents.codex.cmd)
  vim.list_extend(cmd, args)
  return { cmd = cmd, cwd = sess.root }
end

return M
