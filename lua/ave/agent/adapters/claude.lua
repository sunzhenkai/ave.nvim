-- Claude Code：CLI 参数吃 MCP 配置，且支持 --strict-mcp-config 屏蔽用户级配置
local M = {}

function M.spec(sess, cfg)
  local dir = vim.fn.stdpath("cache") .. "/ave/session-" .. sess.id
  vim.fn.mkdir(dir, "p", "0700")
  local file = dir .. "/mcp.json"
  local body = { mcpServers = { ave = { command = cfg.node, args = { cfg.helper, "mcp" } } } }
  if vim.fn.writefile({ vim.json.encode(body) }, file) == -1 then
    return nil, "cannot write " .. file
  end
  sess.mcp_config = file
  local cmd = vim.deepcopy(cfg.agents.claude.cmd)
  vim.list_extend(cmd, { "--mcp-config", file, "--strict-mcp-config" })
  return { cmd = cmd, cwd = sess.root }
end

return M
