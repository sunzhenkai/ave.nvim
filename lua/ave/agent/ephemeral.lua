-- 临时 agent：浮窗里问一个问题就走。和主面板完全独立，不抢主会话的状态。
local M = {}

local state = { win = nil, buf = nil, job = nil, sess = nil, prompt = nil, width = 0.7, height = 0.75 }

local function valid_win(w)
  return w ~= nil and vim.api.nvim_win_is_valid(w)
end

local function valid_buf(b)
  return b ~= nil and vim.api.nvim_buf_is_valid(b)
end

-- 终端退出时自动收尾（连隐藏状态下也收）
local function cleanup()
  local s = state
  state = { win = nil, buf = nil, job = nil, sess = nil, prompt = nil, width = s.width, height = s.height }
  if s.prompt and valid_buf(s.prompt) then
    pcall(vim.api.nvim_buf_delete, s.prompt, { force = true })
  end
  if s.sess then
    if s.sess.cleanup then
      pcall(s.sess.cleanup)
    end
    require("ave.state").stop_session(s.sess)
  end
end

-- 终端缓冲区的退出回调
local function on_exit(buf)
  return function(_, code)
    vim.schedule(function()
      if code ~= 0 then
        vim.notify("ave: agent exited with " .. tostring(code), vim.log.levels.WARN)
      end
      if state.buf == buf then
        cleanup()
      end
    end)
  end
end

-- 临时窗口键位：q 隐藏不退出，i/a 回 terminal-mode，Esc 打断
local function map_term(buf, job)
  local function leave()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true), "n", false)
  end
  local keys = {
    ["<C-n>"] = leave,
    ["<F2>"] = leave,
    ["<Esc>"] = function()
      vim.fn.chansend(job, "\27")
    end,
  }
  for key, dir in pairs({ ["<C-h>"] = "h", ["<C-j>"] = "j", ["<C-k>"] = "k", ["<C-l>"] = "l" }) do
    keys[key] = function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n><C-w>" .. dir, true, false, true), "n", false)
    end
  end
  for key, fn in pairs(keys) do
    vim.keymap.set("t", key, fn, { buffer = buf, silent = true })
  end
  for _, k in ipairs({ "i", "a" }) do
    vim.keymap.set("n", k, function()
      vim.cmd("startinsert")
    end, { buffer = buf, silent = true })
  end
  vim.keymap.set("n", "q", function()
    M.hide()
  end, { buffer = buf, silent = true, desc = "ave: 隐藏浮窗（agent 继续跑）" })
end

function M.hide()
  if valid_win(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
end

function M.is_running()
  return state.job ~= nil
end

-- 创建（或唤回）浮窗
local function open_float(width, height)
  local cols = vim.o.columns
  local lines = vim.o.lines
  local w = math.max(40, math.floor(cols * width))
  local h = math.max(15, math.floor(lines * height))
  local row = math.floor((lines - h) / 2)
  local col = math.floor((cols - w) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "ave-agent"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = w,
    height = h,
    style = "minimal",
    border = "rounded",
    title = " ave agent ",
    title_pos = "center",
    zindex = 50,
  })
  return buf, win
end

-- 问一个问题：在浮窗里启动临时 agent 并贴上问题
function M.ask(opts)
  opts = opts or {}
  -- 已在跑且问题为空：唤回窗口
  if M.is_running() and not opts.question then
    if not valid_win(state.win) and valid_buf(state.buf) then
      local w, h = state.width, state.height
      local cols = vim.o.columns
      local lines = vim.o.lines
      local win = vim.api.nvim_open_win(state.buf, true, {
        relative = "editor",
        row = math.floor((lines - math.floor(lines * h)) / 2),
        col = math.floor((cols - math.floor(cols * w)) / 2),
        width = math.floor(cols * w),
        height = math.floor(lines * h),
        style = "minimal",
        border = "rounded",
        title = " ave agent ",
        title_pos = "center",
        zindex = 50,
      })
      state.win = win
    end
    if valid_win(state.win) then
      vim.api.nvim_set_current_win(state.win)
      vim.cmd("startinsert")
    end
    return true
  end

  -- 已在跑且有新问题：先收掉旧的
  if M.is_running() then
    M.hide()
    if state.job then
      pcall(vim.fn.jobstop, state.job)
    end
    -- cleanup 会由 on_exit 触发；如果没触发（某些 edge），手动补一次
    if state.job then
      cleanup()
    end
  end

  local ok, err = require("ave.bridge").ensure()
  if not ok then
    return nil, err
  end

  local cfg = require("ave.config").get()
  local name = opts.agent or cfg.agent
  local adapter = require("ave.agent.adapters").get(name)
  if not adapter then
    return nil, "unknown agent: " .. tostring(name)
  end
  local sess = require("ave.state").new_session(name)
  local spec, serr = adapter.spec(sess, cfg)
  if not spec then
    require("ave.state").stop_session(sess)
    return nil, serr
  end
  spec.env = vim.tbl_extend("force", {
    WORKBENCH_SOCKET = sess.socket,
    AVE_SESSION = tostring(sess.id),
    AVE_ROOT = sess.root,
  }, spec.env or {})

  local width = opts.width or 0.7
  local height = opts.height or 0.75
  local buf, win = open_float(width, height)
  local job = vim.fn.jobstart(spec.cmd, {
    term = true,
    cwd = spec.cwd,
    env = (spec.env and next(spec.env)) and spec.env or nil,
    on_exit = on_exit(buf),
  })
  if job <= 0 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.api.nvim_win_close, win, true)
    require("ave.state").stop_session(sess)
    return nil, "failed to start: " .. table.concat(spec.cmd, " ")
  end

  sess.win, sess.buf, sess.job, sess.cleanup = win, buf, job, spec.cleanup
  state = { win = win, buf = buf, job = job, sess = sess, width = width, height = height }

  map_term(buf, job)
  -- 隐藏时 BufLeave 不退出
  vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, callback = function() end })

  if opts.question then
    -- bracketed paste 贴入问题，不自动回车
    vim.schedule(function()
      local text = opts.question:gsub("\27", "")
      vim.fn.chansend(job, "\27[200~" .. text .. "\27[201~")
      vim.cmd("startinsert")
    end)
  else
    vim.cmd("startinsert")
  end
  return true
end

-- 退出：停进程 + 关窗口
function M.close()
  M.hide()
  if state.job then
    pcall(vim.fn.jobstop, state.job)
  end
  cleanup()
end

-- 测试用：只装状态，不起进程
function M.__test_attach(buf, win, job, sess)
  state.buf, state.win, state.job, state.sess = buf, win, job or -1, sess
end

function M.__test_detach()
  state = { win = nil, buf = nil, job = nil, sess = nil, prompt = nil, width = 0.7, height = 0.75 }
end

-- 测试用：手动触发 on_exit 的 cleanup 路径
function M.__test_exit()
  if state.buf then
    on_exit(state.buf)(nil, 0)
  end
end

return M
