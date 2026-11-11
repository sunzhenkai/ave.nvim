-- Claude Code：CLI 参数吃 MCP 配置，且支持 --strict-mcp-config 屏蔽用户级配置
local M = {}

local function shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.spec(sess, cfg)
  local dir = vim.fn.stdpath("cache") .. "/ave/session-" .. sess.id
  vim.fn.mkdir(dir, "p", "0700")
  local file = dir .. "/mcp.json"
  local body = { mcpServers = { ave = { command = cfg.node, args = { cfg.helper, "mcp" } } } }
  if vim.fn.writefile({ vim.json.encode(body) }, file) == -1 then
    return nil, "cannot write " .. file
  end
  sess.mcp_config = file

  -- 被动跟随：agent 每次读/改文件，hooks 把编辑器跟过去
  local settings = dir .. "/settings.json"
  local hook_cmd = ("WORKBENCH_SOCKET=%s %s %s hook"):format(shq(sess.socket), cfg.node, shq(cfg.helper))
  local hook_body = {
    hooks = {
      PostToolUse = {
        {
          matcher = "Read|Edit|Write|MultiEdit|NotebookEdit",
          hooks = { { type = "command", command = hook_cmd } },
        },
      },
    },
  }
  if vim.fn.writefile({ vim.json.encode(hook_body) }, settings) ~= -1 then
    sess.settings = settings
  end

  local cmd = vim.deepcopy(cfg.agents.claude.cmd)
  vim.list_extend(cmd, { "--mcp-config", file, "--strict-mcp-config" })
  if sess.settings then
    vim.list_extend(cmd, { "--settings", sess.settings })
  end
  return { cmd = cmd, cwd = sess.root }
end

return M
