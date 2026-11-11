-- 不依赖 bridge 的自检：路径栈、文件解析、router 白名单
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
require("ave").setup({})

local fails = 0
local function check(name, cond, detail)
  if cond then
    io.stdout:write("ok   " .. name .. "\n")
  else
    fails = fails + 1
    io.stdout:write("FAIL " .. name .. (detail and (" -> " .. tostring(detail)) or "") .. "\n")
  end
end

local E = require("ave.editor")
local ex = require("ave.explore")

-- resolve
check("resolve absolute", E.resolve("/tmp/x.lua") == "/tmp/x.lua")
check("resolve relative", E.resolve("lua/ave/init.lua") == root .. "/lua/ave/init.lua")
check("resolve rejects nil", E.resolve(nil) == nil)

-- snippet 定位
local buf = vim.fn.bufadd(root .. "/lua/ave/config.lua")
vim.fn.bufload(buf)
local hit = E.find_snippet(buf, "M.options = vim.deepcopy")
check("snippet finds line", hit ~= nil and hit > 1, hit)
check("snippet miss returns nil", E.find_snippet(buf, "不存在的代码") == nil)

-- 路径栈
ex.reset()
E.open({ file = "lua/ave/config.lua", line = 5 })
E.open({ file = "lua/ave/config.lua", line = 5 })
check("dedupe same hop", #ex.stack == 1, #ex.stack)
E.open({ file = "lua/ave/state.lua", line = 2 })
E.open({ file = "lua/ave/ui/layout.lua", line = 9 })
check("three hops", #ex.stack == 3 and ex.idx == 3, #ex.stack .. "/" .. ex.idx)

local back, berr = ex.back()
check("back moves", back and back.index == 2 and vim.fn.fnamemodify(back.file, ":t") == "state.lua", berr)
check("back jumps buffer", vim.api.nvim_buf_get_name(0) ~= nil)

E.open({ file = "lua/ave/editor/init.lua", line = 3 })
check("branch truncation", #ex.stack == 3 and ex.idx == 3, #ex.stack .. "/" .. ex.idx)
check("truncated tail", vim.fn.fnamemodify(ex.stack[#ex.stack].file, ":t") == "init.lua", ex.stack[#ex.stack].file)

local stale, _ = E.open({ file = "lua/ave/config.lua", line = 1, snippet = "M.options = vim.deepcopy" })
check("stale line relocated", stale and stale.stale == nil and stale.line > 1, vim.inspect(stale))

ex.back()
ex.back()
ex.back()
local _, err = ex.back()
check("back at first fails", err ~= nil, err)
check("forward moves", (ex.forward() or {}).index == 2)

-- loclist
local ll = ex.loclist()
check("loclist built", ll and #vim.fn.getloclist(0) == #ex.stack, #vim.fn.getloclist(0))

-- router 白名单
local r = require("ave.bridge.router")
local ping = r.handle("ping", {})
check("router ping", ping and ping.ok == true)
local res, e = r.handle("nope", {})
check("router rejects unknown", res == nil and e.code == -32601, vim.inspect(e))
local methods = table.concat(r.methods(), ",")
check("router exposes editor.lsp", methods:find("editor.lsp", 1, true) ~= nil, methods)

-- 持久化往返
ex.save()
local saved = #ex.stack
ex.reset()
check("load restores", ex.load() and #ex.stack == saved, #ex.stack .. "/" .. saved)
check("load keeps index", ex.idx <= #ex.stack)

io.stdout:write(fails == 0 and "ALL PASS\n" or ("FAILED " .. fails .. "\n"))
vim.cmd(fails == 0 and "qa!" or "cq!")
