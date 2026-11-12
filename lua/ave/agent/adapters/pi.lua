-- Pi：MCP 只认用户级 ~/.pi/agent/mcp.json，且默认 exposure=codemode 时工具不给模型
local M = {}

local function config_file()
  return vim.fn.expand("~/.pi/agent/mcp.json")
end

local function read(path)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local lines = vim.fn.readfile(path)
  local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

function M.install(cfg)
  local path = config_file()
  local data = read(path)
  data.mcpServers = data.mcpServers or {}
  data.mcpServers.ave = {
    command = cfg.node,
    args = { cfg.helper, "mcp" },
    exposure = "direct",
  }
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  if vim.fn.writefile({ vim.json.encode(data) }, path) == -1 then
    return nil, "cannot write " .. path
  end
  return path
end

function M.spec(sess, cfg)
  local entry = read(config_file()).mcpServers
  entry = entry and entry.ave
  if not entry then
    return nil, "pi 需要先运行 :Ave install pi 写入用户级 MCP 配置"
  end
  local cmd = vim.deepcopy(cfg.agents.pi.cmd)
  vim.list_extend(cmd, { "--append-system-prompt", require("ave.agent.adapters").directive })
  return { cmd = cmd, cwd = sess.root }
end

return M
