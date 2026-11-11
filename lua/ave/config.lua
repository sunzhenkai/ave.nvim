local M = {}

M.defaults = {
  agent = "claude",
  width = 0.25,
  -- 打开面板后把焦点留在编辑器；用户在 agent 输入框里打字时不会被抢走
  focus_on_open = false,
  esc_double = true, -- agent 面板里双击 Esc 回 normal mode，单击原样给 agent
  node = "node",
  helper = nil,
  socket_dir = nil,
  keys = { toggle = "<leader>aa", back = "<leader>a[", forward = "<leader>a]", path = "<leader>al", send = "<leader>as", full = "<leader>aF", jump = "<leader>ag" },
  agents = {
    claude = { cmd = { "claude" } },
    codex = { cmd = { "codex" } },
    pi = { cmd = { "pi" } },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  local o = vim.tbl_extend("force", M.defaults, opts or {})
  -- agents 整表替换，避免列表按索引合并
  o.agents = (opts and opts.agents) or M.defaults.agents
  M.options = o
  return o
end

function M.get()
  return M.options
end

return M
