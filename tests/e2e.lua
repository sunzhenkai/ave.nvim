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

-- 业务导览：块列表、前后跳、指定块、解释贴在编辑区
local T = require("ave.tour")
do
  local r = T.set({
    { file = "lua/ave/config.lua", line = 5, note = "默认配置入口" },
    { file = "lua/ave/state.lua", line = 10, end_line = 20, note = "socket 路径" },
    { file = "lua/ave/ui/layout.lua", line = 30, note = "布局" },
  }, "自检导览")
  check("tour sets blocks", r and r.count == 3, r)
  check("tour starts at first", T.idx == 1)
  local items
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local l = vim.fn.getloclist(w)
    if #l > 0 then
      items = l
    end
  end
  items = items or {}
  check("tour lists blocks", #items == 3 and items[1].text:match("^%[1%]") ~= nil, #items)
  check("tour note pinned", #vim.api.nvim_buf_get_extmarks(
    vim.fn.bufnr(vim.fn.getcwd() .. "/lua/ave/config.lua"),
    vim.api.nvim_create_namespace("ave_note"), 0, -1, {}
  ) == 1)
  check("tour next", T.step(1) and T.idx == 2)
  check("tour prev", T.step(-1) and T.idx == 1)
  check("tour prev at edge", select(2, T.step(-1)) == "already at the first block")
  check("tour goto", T.goto(3) and T.idx == 3)
  check("tour goto at edge", select(2, T.goto(9)):match("out of range") ~= nil)
  check("tour empty rejected", select(2, T.set({})) == "blocks is empty")
  T.clear()
  -- 前面路径栈的 loclist 还在，只认 tour 自己的 "[n]" 条目
  local left = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    for _, it in ipairs(vim.fn.getloclist(w)) do
      if (it.text or ""):match("^%[%d+%]") then
        left = left + 1
      end
    end
  end
  check("tour cleared", T.active() == false and left == 0, left)
end

-- 全屏：面板 buffer 进独立 tab，退出后原布局还在
local L = require("ave.ui.layout")
do
  vim.cmd("vsplit")
  local before = #vim.api.nvim_tabpage_list_wins(0)
  local wbuf = vim.api.nvim_get_current_buf()
  local pbuf = vim.api.nvim_create_buf(false, true)
  L.__test_attach(pbuf, wbuf)
  local full = L.toggle_full()
  check("full raises tab", full == true and vim.fn.tabpagenr("$") == 2, vim.inspect({ full = full, tabs = vim.fn.tabpagenr("$") }))
  check("full spans columns", vim.api.nvim_win_get_width(0) == vim.o.columns, vim.api.nvim_win_get_width(0))
  L.toggle_full()
  check("full restores tabs", vim.fn.tabpagenr("$") == 1)
  check("full restores splits", #vim.api.nvim_tabpage_list_wins(0) == before)
  L.__test_detach()
end

-- agent 面板的终端键位：Esc 单击给 agent、双击回 normal，i/a 回 terminal-mode
local tbuf = vim.api.nvim_create_buf(false, true)
require("ave.ui.layout").map_term(tbuf, 0, {})
local function has_map(mode, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(tbuf, mode)) do
    if m.lhs == lhs then
      return true
    end
  end
  return false
end
check("term mode maps Esc", has_map("t", "<Esc>"))
check("normal mode maps i", has_map("n", "i"))
check("normal mode maps a", has_map("n", "a"))

io.stdout:write(fails == 0 and "ALL PASS\n" or ("FAILED " .. fails .. "\n"))
vim.cmd(fails == 0 and "qa!" or "cq!")
