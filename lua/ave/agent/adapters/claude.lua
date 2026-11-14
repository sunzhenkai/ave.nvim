-- Claude Code：CLI 参数吃 MCP 配置，且支持 --strict-mcp-config 屏蔽用户级配置
local M = {}

M.directive = "claude 把 MCP 工具压成 deferred；仅在确需调用某个 ave 工具时先 ToolSearch 加载对应工具，否则不要加载。"
  .. require("ave.agent.adapters").directive

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
  -- deferred 工具只按上面的触发边界加载，普通文件读写不再注册被动跟随 hook。
  vim.list_extend(cmd, { "--append-system-prompt", M.directive })
  return { cmd = cmd, cwd = sess.root, cleanup = function()
    vim.fn.delete(dir, "rf")
  end }
end

return M
