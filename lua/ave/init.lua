local M = {}
-- 定义在下面，键位回调里要用
local send_text

local function plugin_root()
  local f = vim.api.nvim_get_runtime_file("lua/ave/init.lua", false)[1]
  if not f then
    return nil
  end
  return f:gsub("/lua/ave/init%.lua$", "")
end

function M.register_commands()
  if vim.fn.exists(":Ave") == 2 then
    return
  end
  vim.api.nvim_create_user_command("Ave", function(a)
    M.dispatch(a.fargs)
  end, {
    nargs = "*",
    complete = function()
      return { "open", "pick", "close", "toggle", "stop", "status", "install", "back", "forward", "path", "send", "ref", "full", "tour", "goto" }
    end,
    desc = "ave: native agent panel",
  })
end

function M.setup(opts)
  M.register_commands()
  local cfg = require("ave.config").setup(opts)
  if not cfg.helper then
    local root = plugin_root()
    if root then
      cfg.helper = root .. "/bridge-helper/index.mjs"
    end
  end

  local group = vim.api.nvim_create_augroup("ave", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local w = vim.api.nvim_get_current_win()
      local b = vim.api.nvim_win_get_buf(w)
      -- 只认真正显示文件的窗口：面板（terminal）、loclist/quickfix（buftype 或空名字）
      -- 都不算，否则 agent 的跳转会写进列表窗口
      local bt = vim.bo[b].buftype
      if (bt == "" or bt == "acwrite") and vim.api.nvim_buf_get_name(b) ~= "" then
        require("ave.ui.layout").set_work_win(w)
      end
    end,
  })
  -- 跳转遇到遗留 swap 文件时不要弹模态框：agent 触发的跳转不该卡住编辑器
  vim.api.nvim_create_autocmd("SwapExists", {
    group = group,
    callback = function()
      if require("ave.editor").navigating then
        vim.v.swapchoice = "e"
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("ave.ui.layout").close()
      require("ave.bridge").stop()
    end,
  })

  if cfg.keys and cfg.keys.toggle then
    local binds = {
      { cfg.keys.toggle, "pick", "ave: pick and start agent" },
      { cfg.keys.back, "back", "ave: path back" },
      { cfg.keys.forward, "forward", "ave: path forward" },
      { cfg.keys.path, "path", "ave: path list" },
      { cfg.keys.full, "full", "ave: agent panel fullscreen" },
      { cfg.keys.ref, "ref", "ave: send file:line reference to agent" },
    }
    for _, b in ipairs(binds) do
      if b[1] then
        vim.keymap.set("n", b[1], function()
          M.dispatch({ b[2] })
        end, { desc = b[3] })
      end
    end
    -- 引用式在 visual 下也要能用
    if cfg.keys.ref then
      vim.keymap.set("x", cfg.keys.ref, function()
        M.dispatch({ "ref" })
      end, { desc = "ave: send file:line reference to agent" })
    end
    -- 选区原文：visual 发选中的行，normal 发当前行；send_focus 发完切到面板
    for _, s in ipairs({
      { cfg.keys.send, false, "ave: send text to agent" },
      { cfg.keys.send_focus, true, "ave: send text and focus agent" },
    }) do
      if s[1] then
        for _, mode in ipairs({ "n", "x" }) do
          vim.keymap.set(mode, s[1], function()
            local res, err = send_text(mode == "x", s[2])
            if not res then
              notify(tostring(err), vim.log.levels.WARN)
            end
          end, { desc = s[3] })
        end
      end
    end
    -- 计数前缀直接跳块：3<leader>ag；不带计数就提示输入
    if cfg.keys.jump then
      vim.keymap.set("n", cfg.keys.jump, function()
        local n = vim.v.count > 0 and vim.v.count or tonumber(vim.fn.input("tour block: "))
        if n then
          M.dispatch({ "goto", tostring(n) })
        end
      end, { desc = "ave: jump to tour block (count)" })
    end
  end
  return cfg
end

local function notify(msg, level)
  vim.notify("ave: " .. msg, level or vim.log.levels.INFO)
end

-- 选区原样文本（按整行取）；visual=false 时只取光标所在行
local function selected_text(visual)
  local buf = vim.api.nvim_get_current_buf()
  local first, last
  if visual then
    local s = vim.api.nvim_buf_get_mark(buf, "<")
    local e = vim.api.nvim_buf_get_mark(buf, ">")
    if s[1] > 0 and e[1] >= s[1] then
      first, last = s[1], e[1]
    end
  end
  first = first or vim.api.nvim_win_get_cursor(0)[1]
  last = last or first
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, first - 1, last, false), "\n")
  if text:gsub("%s", "") == "" then
    return nil, "selection is empty"
  end
  return text
end

-- bracketed paste 上限：再大就糊不进 TUI 了，也更该用引用式
local MAX_LINES = 200

-- 把选区原文贴进 agent 输入框；focus=true 时切过去并进输入模式（都不回车）
function send_text(visual, focus)
  local layout = require("ave.ui.layout")
  if not layout.is_open() then
    return nil, "agent is not running"
  end
  local text, err = selected_text(visual)
  if not text then
    return nil, err
  end
  local lines = select(2, text:gsub("\n", "")) + 1
  if lines > MAX_LINES then
    return nil, ("selection too large (%d lines > %d), use %s"):format(lines, MAX_LINES, require("ave.config").get().keys.ref)
  end
  -- 文本里的 ESC 会提前截断 paste 边界、或触发控制序列，必须剥掉
  text = text:gsub("\27", "")
  local ok, serr = layout.send("\27[200~" .. text .. "\27[201~")
  if not ok then
    return nil, serr
  end
  if focus then
    layout.focus()
    vim.cmd("startinsert")
  end
  return true
end

-- 把选区（或当前行）变成 "@相对路径:Lx-Ly " 粘进 agent 输入框，不自动回车
local function send_selection()
  local layout = require("ave.ui.layout")
  if not layout.is_open() then
    return nil, "agent is not running"
  end
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return nil, "current buffer has no file"
  end
  local rel = vim.fs.relpath(require("ave.state").root or vim.fn.getcwd(), path) or path
  local s = vim.api.nvim_buf_get_mark(buf, "<")
  local e = vim.api.nvim_buf_get_mark(buf, ">")
  local range
  if s[1] > 0 and e[1] >= s[1] then
    range = s[1] == e[1] and (":L" .. s[1]) or (":L" .. s[1] .. "-L" .. e[1])
  else
    range = ":L" .. vim.api.nvim_win_get_cursor(0)[1]
  end
  return layout.send("@" .. rel .. range .. " ")
end

local function install_helper(cfg)
  local dir = vim.fs.dirname(cfg.helper)
  if vim.fn.isdirectory(dir) == 0 then
    return notify("helper 目录不存在: " .. dir, vim.log.levels.ERROR)
  end
  notify("npm ci in " .. dir)
  vim.fn.jobstart({ "npm", "ci", "--omit=dev" }, {
    cwd = dir,
    on_exit = function(_, code)
      vim.schedule(function()
        notify("npm ci exit " .. tostring(code), code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
      end)
    end,
  })
end

-- 用 vim.ui.select：用户装了 snacks/telescope 就是浮窗，没装走内置列表
local function pick_agent()
  local names = vim.tbl_keys(require("ave.config").get().agents or {})
  table.sort(names)
  vim.ui.select(names, { prompt = "ave: 启动哪个 agent" }, function(choice)
    if choice then
      M.dispatch({ "open", choice })
    end
  end)
end

function M.dispatch(args)
  local sub = args[1] or "toggle"
  local manager = require("ave.agent.manager")
  local cfg = require("ave.config").get()

  if sub == "open" then
    local sess, err = manager.start(args[2])
    if not sess then
      notify(tostring(err), vim.log.levels.ERROR)
    end
  elseif sub == "pick" then
    pick_agent()
  elseif sub == "toggle" then
    local sess, err = manager.toggle()
    if sess == nil and err then
      notify(tostring(err), vim.log.levels.ERROR)
    end
  elseif sub == "back" or sub == "forward" then
    -- 有导览就沿导览走，没有才走 agent 留下的足迹
    local res, err
    if require("ave.tour").active() then
      res, err = require("ave.tour").step(sub == "forward" and 1 or -1)
    else
      res, err = require("ave.explore")[sub]()
    end
    if not res then
      notify(tostring(err), vim.log.levels.WARN)
    else
      notify(("%s %d/%d "):format(sub, res.index, res.total) .. vim.fn.fnamemodify(res.file, ":t"), vim.log.levels.INFO)
    end
  elseif sub == "send" then
    local res, err = send_text(false, args[2] == "focus")
    if not res then
      notify(tostring(err), vim.log.levels.WARN)
    end
  elseif sub == "ref" then
    local res, err = send_selection()
    if not res then
      notify(tostring(err), vim.log.levels.WARN)
    end
  elseif sub == "path" then
    local res, err = require("ave.explore").loclist()
    if not res then
      notify(tostring(err), vim.log.levels.WARN)
    end
  elseif sub == "tour" then
    local tour = require("ave.tour")
    if args[2] == "off" then
      tour.clear()
      return notify("tour cleared")
    end
    local res, err = tour.show()
    if not res then
      return notify(tostring(err), vim.log.levels.WARN)
    end
  elseif sub == "goto" then
    local n = tonumber(args[2])
    if not n then
      return notify("usage: :Ave goto <index>", vim.log.levels.WARN)
    end
    local res, err = require("ave.tour").goto(n)
    if not res then
      return notify(tostring(err), vim.log.levels.WARN)
    end
    notify(("tour %d/%d "):format(res.index, res.total) .. vim.fn.fnamemodify(res.file, ":t"), vim.log.levels.INFO)
  elseif sub == "full" then
    local full, err = require("ave.ui.layout").toggle_full()
    if full == nil then
      notify(tostring(err), vim.log.levels.WARN)
    end
  elseif sub == "close" or sub == "stop" then
    manager.stop()
  elseif sub == "status" then
    local st = require("ave.state")
    notify(
      table.concat({
        "helper=" .. tostring(cfg.helper),
        "socket=" .. tostring(st.socket),
        "server=" .. (st.server and "up" or "down"),
        "running=" .. tostring(manager.is_running()),
        "full=" .. tostring(require("ave.ui.layout").is_full()),
        "agent=" .. (st.current and (st.current.agent .. "#" .. st.current.id) or "-"),
      }, " "),
      vim.log.levels.INFO
    )
  elseif sub == "install" then
    if args[2] == "pi" then
      local path, err = require("ave.agent.adapters.pi").install(cfg)
      return notify(path and ("wrote " .. path) or tostring(err), path and vim.log.levels.INFO or vim.log.levels.ERROR)
    end
    install_helper(cfg)
  else
    notify("unknown subcommand: " .. sub, vim.log.levels.ERROR)
  end
end

-- 测试用：视觉路径没法从命令走
M.__test_send = send_text

return M
