local M = {}

M.defaults = {
  agent = "claude",
  width = 0.25,
  -- 打开面板后直接把焦点交给 agent 并进输入模式（设 false 就留在编辑器）
  focus_on_open = true,
  -- Esc 一律给 agent（打断）；true 时 300ms 内按两下才回 normal mode
  esc_double = false, -- agent 面板里双击 Esc 回 normal mode，单击原样给 agent
  node = "node",
  helper = nil,
  socket_dir = nil,
  keys = { toggle = "<leader>aa", back = "<leader>a[", forward = "<leader>a]", path = "<leader>al", send = "<leader>as", send_focus = "<leader>aS", ref = "<leader>aR", full = "<leader>aF", jump = "<leader>ag", ask = "<leader>aq" },
  agents = {
    claude = { cmd = { "claude" } },
    codex = { cmd = { "codex" } },
    pi = { cmd = { "pi" } },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  local o = vim.tbl_extend("force", M.defaults, opts or {})
  -- agents 按单个 agent 替换整表（cmd 是列表，不能按下标合并），但没写到的 agent 保留默认，
  -- 否则只配 claude 就会把 codex/pi 一起抹掉
  o.agents = vim.tbl_extend("force", vim.deepcopy(M.defaults.agents), (opts and opts.agents) or {})
  -- keys 同理：只改一个键不能把其余的漏成 nil
  o.keys = vim.tbl_extend("force", M.defaults.keys, (opts and opts.keys) or {})
  M.options = o
  return o
end

function M.get()
  return M.options
end

return M
