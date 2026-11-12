-- Claude Code：CLI 参数吃 MCP 配置，且支持 --strict-mcp-config 屏蔽用户级配置
local M = {}

M.directive = table.concat({
  "你在 ave（Neovim 插件）里运行，编辑器已连上。",
  "梳理跨文件流程或调用链时：先用 ToolSearch 加载 mcp__ave__* 工具，",
  "然后用一次 editor_tour 把有序代码块推给编辑器（缺的块用 append 追加），",
  "只输出文字报告、不做编辑器展示视为任务未完成。",
  "查单个实现用 editor_open，查定义/引用用 editor_lsp。",
}, "")

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
  -- claude 会把 MCP 工具压成 deferred（只有名字、没有 schema），且 user skill 的输出模板
  -- 优先级高于 MCP instructions；实测只加载 code-explore 时它一次 ave 工具都不调。
  -- system prompt 优先级最高，用它把「必须推 tour」这条压过 skill。
  vim.list_extend(cmd, { "--append-system-prompt", M.directive })
  if sess.settings then
    vim.list_extend(cmd, { "--settings", sess.settings })
  end
  return { cmd = cmd, cwd = sess.root, cleanup = function()
    vim.fn.delete(dir, "rf")
  end }
end

return M
