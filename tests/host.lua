-- 为 MCP e2e 起一个真 nvim：桥 + clangd，30 秒后自退
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
require("ave").setup({})
local st = require("ave.state")
local ok, err = require("ave.bridge").ensure()
if not ok then
  vim.fn.writefile({ "ERR " .. tostring(err) }, "/tmp/ave-mcp-e2e.err")
  vim.cmd("cq")
end
vim.fn.writefile({ st.socket }, "/tmp/ave-mcp-e2e.sock")

-- clangd：definition/references 用（pyright 在 nvim 0.12 下 pull-diagnostics 会卡死）
local fixture = root .. "/tests/lsp_fixture"
local buf = vim.fn.bufadd(fixture .. "/b.c")
vim.fn.bufload(buf)
vim.api.nvim_set_current_buf(buf)
vim.lsp.start({
  name = "clangd",
  cmd = { vim.fn.expand("~/.local/share/nvim/mason/bin/clangd") },
  root_dir = fixture,
})
vim.wait(8000, function()
  return #vim.lsp.get_clients({ bufnr = buf, name = "clangd" }) > 0
end)

vim.defer_fn(function()
  vim.cmd("qa!")
end, 30000)
