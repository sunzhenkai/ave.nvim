local M = {}

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
      return { "open", "close", "toggle", "stop", "status", "install", "back", "forward", "path", "send", "full", "tour", "goto" }
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
      { cfg.keys.toggle, "toggle", "ave: toggle agent panel" },
      { cfg.keys.back, "back", "ave: path back" },
      { cfg.keys.forward, "forward", "ave: path forward" },
      { cfg.keys.path, "path", "ave: path list" },
      { cfg.keys.send, "send", "ave: send selection to agent" },
      { cfg.keys.full, "full", "ave: agent panel fullscreen" },

    }
    for _, b in ipairs(binds) do
      if b[1] then
        vim.keymap.set("n", b[1], function()
          M.dispatch({ b[2] })
        end, { desc = b[3] })
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

function M.dispatch(args)
  local sub = args[1] or "toggle"
  local manager = require("ave.agent.manager")
  local cfg = require("ave.config").get()

  if sub == "open" then
    local sess, err = manager.start(args[2])
    if not sess then
      notify(tostring(err), vim.log.levels.ERROR)
    end
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

return M
