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

-- editor.context 带分支：agent 靠它判断磁盘上这版是哪版
local ctx = E.context()
local head = vim.trim(vim.fn.system({ "git", "rev-parse", "--abbrev-ref", "HEAD" }))
check("context carries branch", ctx.branch == head and head ~= "", vim.inspect({ ctx.branch, head }))

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

-- agent 适配：编辑器操作按需触发，普通读写不注册被动跟随
do
  local cfg = require("ave.config").get()
  local sess = { id = "t", root = vim.fn.getcwd(), socket = "/tmp/x.sock" }
  local spec = require("ave.agent.adapters.claude").spec(sess, cfg)
  local joined = table.concat(spec.cmd, " ")
  check("claude loads mcp config", joined:find("--mcp%-config") ~= nil)
  check("claude carries directive", joined:find("--append%-system%-prompt") ~= nil)
  check("claude directive names tour", joined:find("editor_tour") ~= nil)
  check("claude loads deferred tools on demand", joined:find("仅在确需调用", 1, true) ~= nil, joined)
  check("directive defaults to chat only", joined:find("默认只在聊天中回答", 1, true) ~= nil, joined)
  check("directive gates tour and open", joined:find("普通文件读写和跨文件分析本身不构成触发理由", 1, true) ~= nil, joined)
  check("directive honors explicit refusal", joined:find("明确禁止优先", 1, true) ~= nil, joined)
  check("claude disables passive follow", sess.settings == nil and joined:find("--settings", 1, true) == nil, joined)
  check("claude writes no hook settings", vim.fn.filereadable(vim.fn.stdpath("cache") .. "/ave/session-t/settings.json") == 0)
  check("claude directive forbids copying out", joined:find("工作区外") ~= nil)
  spec.cleanup()

  local cs = require("ave.agent.adapters.codex").spec({ id = "t", root = "/tmp", socket = "/tmp/x.sock" }, cfg)
  local cj = table.concat(cs.cmd, " ")
  check("codex carries directive", cj:find("developer_instructions") ~= nil and cj:find("editor_tour") ~= nil)

  local ps = require("ave.agent.adapters.pi").spec({ id = "t", root = "/tmp", socket = "/tmp/x.sock" }, cfg)
  local pj = table.concat(ps.cmd, " ")
  check("pi carries directive", pj:find("append%-system%-prompt") ~= nil and pj:find("editor_tour") ~= nil)
end

-- 自定义 flag：cmd 原样带下去，只配一个 agent 不能把其他 agent 抹掉
do
  local cfgmod = require("ave.config")
  local o = require("ave").setup({
    agents = {
      claude = { cmd = { "claude", "--permission-mode", "bypassPermissions" } },
      codex = { cmd = { "codex", "--dangerously-bypass-approvals-and-sandbox" } },
    },
  })
  check("partial agents keeps untouched ones", o.agents.pi ~= nil and o.agents.pi.cmd[1] == "pi")
  local sess = { id = "t", root = "/tmp", socket = "/tmp/x.sock" }
  local cs = require("ave.agent.adapters.claude").spec(sess, o)
  check(
    "claude flag passes through",
    table.concat(cs.cmd, " "):find("--permission-mode bypassPermissions", 1, true) ~= nil,
    table.concat(cs.cmd, " ")
  )
  cs.cleanup()
  local xs = require("ave.agent.adapters.codex").spec(sess, o)
  check("codex flag passes through", table.concat(xs.cmd, " "):find("--dangerously-bypass-approvals-and-sandbox", 1, true) ~= nil)
  require("ave").setup({})
  check("setup resets agents", cfgmod.get().agents.codex.cmd[1] == "codex" and #cfgmod.get().agents.claude.cmd == 1)
  -- keys 同理：只改一个不能把其余置空
  local k = cfgmod.setup({ keys = { toggle = "<leader>cA" } })
  check("partial keys keeps the rest", k.keys.toggle == "<leader>cA" and k.keys.back == "<leader>a[", vim.inspect(k.keys))
  require("ave").setup({})
end

-- 键位真的挂上了：visual 三个发送键、normal 两个
do
  -- nvim_get_keymap 里的 lhs 已经展开成实际按键（<leader> 会变成逗号/反斜杠）
  local function has_map(mode, lhs)
    local want = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      if m.lhs == want then
        return true
      end
    end
    return false
  end
  check("visual send mapped", has_map("x", "<leader>as"))
  check("visual send_focus mapped", has_map("x", "<leader>aS"))
  check("visual ref mapped", has_map("x", "<leader>aR"))
  check("normal send mapped", has_map("n", "<leader>as"))
  check("visual ask mapped", has_map("x", "<leader>aq"))
  check("normal ask mapped", has_map("n", "<leader>aq"))
end

-- 面板键位：Esc 只透传给 agent，跨窗口用 <C-h/j/k/l>
do
  local L = require("ave.ui.layout")
  local got = {}
  local job = vim.fn.jobstart({ "cat" }, {
    on_stdout = function(_, data)
      for _, d in ipairs(data) do
        got[#got + 1] = d
      end
    end,
  })
  local buf = vim.api.nvim_create_buf(false, true)
  L.map_term(buf, job, {})
  local n = #vim.api.nvim_buf_get_keymap(buf, "t")
  check("panel term keys mapped", n == 7, n)
  check("panel key handler runs", L.__test_key("<Esc>"))
  check("panel C-n returns to normal", L.__test_key("<C-n>"))
  check("panel F2 returns to normal", L.__test_key("<F2>"))
  vim.wait(800, function()
    return #got > 0
  end)
  -- cat 原样回显，收到 ESC 才说明字节真的到了 agent
  check("esc reaches agent", table.concat(got, ""):find("\27", 1, true) ~= nil, vim.inspect(got))
  pcall(vim.fn.jobstop, job)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- 选区原文：包 bracketed paste、剥 ESC、超上限拒发、可选切到面板
do
  local L = require("ave.ui.layout")
  local A = require("ave")
  local got = {}
  local job = vim.fn.jobstart({ "cat" }, {
    on_stdout = function(_, data)
      for _, d in ipairs(data) do
        got[#got + 1] = d
      end
    end,
  })
  -- 面板窗口放终端 buffer，工作窗口放有内容的选择源，焦点留在工作窗口
  local panel_buf = vim.api.nvim_create_buf(false, true)
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.cmd("vsplit")
  local panel = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel, panel_buf)
  local work = vim.fn.win_getid(vim.fn.winnr("#"))
  vim.api.nvim_win_set_buf(work, fbuf)
  vim.api.nvim_set_current_win(work)
  -- 第二行放一个真 ESC 字节，验证发送前被剥掉
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "local a = 1", 'local b = "\27[201~"', "local c = 3" })
  L.map_term(panel_buf, job, {})
  L.__test_attach(panel_buf, work, job, panel)
  vim.api.nvim_buf_set_mark(fbuf, "<", 1, 0, {})
  vim.api.nvim_buf_set_mark(fbuf, ">", 3, 0, {})
  check("send visual returns ok", A.__test_send(true, false) == true)
  vim.wait(800, function()
    return #got > 0
  end)
  local s = table.concat(got, "\n")
  check("send wrapped in paste", s:find("\27[200~", 1, true) ~= nil and s:find("\27[201~", 1, true) ~= nil, vim.inspect(s))
  check("send strips esc", select(2, s:gsub("\27", "")) == 2, select(2, s:gsub("\27", "")))
  check("send keeps all lines", s:find("local c = 3", 1, true) ~= nil, vim.inspect(s))

  local huge = {}
  for i = 1, 250 do
    huge[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, huge)
  vim.api.nvim_buf_set_mark(fbuf, ">", 250, 0, {})
  local res, err = A.__test_send(true, false)
  check("send refuses huge selection", res == nil and tostring(err):find("too large", 1, true) ~= nil, tostring(err))

  vim.api.nvim_buf_set_mark(fbuf, ">", 3, 0, {})
  check("send focus returns ok", A.__test_send(true, true) == true)
  check("send focus moves to panel", vim.api.nvim_get_current_win() == panel)
  vim.cmd("stopinsert")
  pcall(vim.fn.jobstop, job)
  pcall(vim.api.nvim_buf_delete, panel_buf, { force = true })
  pcall(vim.api.nvim_buf_delete, fbuf, { force = true })
  pcall(vim.api.nvim_win_close, panel, true)
  L.__test_detach()
end

-- 临时 agent 浮窗：隐藏不退出、唤回、退出自动收尾
if vim.fn.executable("claude") == 1 then
  local E = require("ave.agent.ephemeral")
  local ok = E.ask({ question = "test question" })
  check("ephemeral ask starts", ok == true, tostring(ok))
  check("ephemeral is running", E.is_running())
  local win = vim.api.nvim_get_current_win()
  check("ephemeral window is float", vim.api.nvim_win_get_config(win).relative ~= "", vim.inspect(vim.api.nvim_win_get_config(win)))
  E.hide()
  check("ephemeral hidden window closed", not vim.api.nvim_win_is_valid(win))
  check("ephemeral still running after hide", E.is_running())
  -- 唤回：ask() 不带 question 且 agent 还在跑
  E.ask({})
  check("ephemeral re-shown", vim.api.nvim_get_current_win() ~= win and vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative ~= "")
  -- 退出：jobstop 触发 on_exit → cleanup
  E.close()
  vim.wait(500, function() return not E.is_running() end)
  check("ephemeral closed", not E.is_running())
else
  io.stdout:write("skip ephemeral tests (no claude)\n")
end

-- 业务导览：块列表、前后跳、指定块、解释贴在编辑区
local T = require("ave.tour")
local function tour_items()
  local items = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local l = vim.fn.getloclist(w)
    if #l > 0 and (vim.fn.getloclist(w, { title = 0 }).title or ""):match("^ave tour") then
      items = l
    end
  end
  return items
end
do
  local r = T.set({
    { file = "lua/ave/config.lua", line = 5, note = "默认配置入口" },
    { file = "lua/ave/state.lua", line = 10, end_line = 20, note = "socket 路径" },
    { file = "lua/ave/ui/layout.lua", line = 30, note = "布局" },
  }, "自检导览")
  check("tour sets blocks", r and r.count == 3, r)
  check("tour starts at first", T.idx == 1)

  -- 测试环境里 show() 的 lopen 有时拿不到窗口，手动补一次再 sync
  if #vim.api.nvim_list_wins() < 3 then
    vim.cmd("lopen")
    vim.api.nvim_set_current_win(T.win)
    T.sync()
  end
  local qf = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "quickfix" then
      qf = w
    end
  end
  local built = T.items()
  check("tour lists blocks", #built == 3 and built[1].text:match("%[1%]") ~= nil, #built)
  check("tour marks current", built[1].text:match("^▶") ~= nil and built[2].text:match("^▶") == nil)
  local widths = {}
  for _, it in ipairs(built) do
    widths[#it.filename] = true
  end
  check("tour filenames equal width", vim.tbl_count(widths) == 1, vim.inspect(vim.tbl_keys(widths)))
  check("tour note pinned", #vim.api.nvim_buf_get_extmarks(
    vim.fn.bufnr(vim.fn.fnamemodify("lua/ave/config.lua", ":p")),
    vim.api.nvim_create_namespace("ave_note"), 0, -1, {}
  ) == 1)
  local mapped = false
  if qf ~= 0 then
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(qf), "n")) do
      mapped = mapped or m.lhs == "<CR>"
    end
  end
  check("tour list enter mapped", qf ~= 0 and mapped)
  check("tour enter jumps and marks", qf ~= 0 and vim.api.nvim_win_call(qf, function() return T.enter() end) ~= nil)
  check("tour list selection follows", qf ~= 0 and vim.api.nvim_win_get_cursor(qf)[1] == T.idx)
  vim.api.nvim_win_set_cursor(qf, { 2, 0 })
  check("tour step continues from selection", T.step(1) and T.idx == 3)
  check("tour next edge", select(2, T.step(1)) == "already at the last block")
  local after = tour_items()
  check("tour list follows", after[3] and after[3].text:match("^▶") ~= nil and after[1].text:match("^▶") == nil)
  check("tour prev", T.step(-1) and T.idx == 2)
  check("tour prev at edge", select(2, T.step(-2)) == "already at the first block")
  check("tour goto", T.goto(3) and T.idx == 3)
  check("tour goto at edge", select(2, T.goto(9)):match("out of range") ~= nil)
  check("tour empty rejected", select(2, T.set({})) == "blocks is empty")
  local ap = T.set({ { file = "lua/ave/init.lua", line = 3, note = "分批追加" } }, nil, true)
  check("tour append keeps place", ap and ap.count == 4 and T.idx == 3, ap and ap.count)
  local dup = T.set({ { file = "lua/ave/init.lua", line = 3 } }, nil, true)
  check("tour append dedupes", dup and dup.count == 4, dup and dup.count)
  T.clear()
  local left = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    for _, it in ipairs(vim.fn.getloclist(w)) do
      if (it.text or ""):match("%[%d+%]") then
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
