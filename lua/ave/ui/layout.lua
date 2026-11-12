-- 右侧终端面板。只负责窗口/缓冲区/进程，不碰 agent 语义。
local M = {}

local state = { win = nil, buf = nil, job = nil, work_win = nil }

local function valid_win(w)
  return w ~= nil and vim.api.nvim_win_is_valid(w)
end

function M.work_win()
  if valid_win(state.work_win) then
    return state.work_win
  end
  -- 没有记录时：取一个非终端窗口，避免把内容塞进 agent 面板
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= state.win then
      return w
    end
  end
  return vim.api.nvim_get_current_win()
end

function M.set_work_win(w)
  state.work_win = w
end

-- 当前 agent 的 job id（nil 表示没跑）
function M.job()
  return state.job
end

function M.is_open()
  return valid_win(state.win) and state.job ~= nil
end

-- 先转好 termcodes，keymap 里再拼容易把 <C-\> 当字面量
local LEAVE = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
local last_esc = 0

-- 键位处理函数单独存一份：keymap 只是壳，测试可以直接调
local term_keys = {}

function M.map_term(buf, job, spec)
  spec = spec or {}
  term_keys = {}
  -- Esc 只做打断：agent 拿它中断输出，拦截它就是抢用户的键。
  -- 要回 normal mode 按 <C-\><C-n>；要离开面板直接 <C-h/j/k/l>。
  term_keys["<Esc>"] = function()
    if spec.esc_double then
      local now = vim.uv.now()
      if last_esc > 0 and now - last_esc < 300 then
        last_esc = 0
        vim.api.nvim_feedkeys(LEAVE, "n", false)
        return
      end
      last_esc = now
    end
    vim.fn.chansend(job, "\27")
  end
  for key, dir in pairs({ ["<C-h>"] = "h", ["<C-j>"] = "j", ["<C-k>"] = "k", ["<C-l>"] = "l" }) do
    term_keys[key] = function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n><C-w>" .. dir, true, false, true), "n", false)
    end
  end
  for key, fn in pairs(term_keys) do
    vim.keymap.set("t", key, fn, { buffer = buf, silent = true, desc = "ave: " .. key })
  end
  -- terminal buffer 的 normal mode 里 i/a 不会自动回到 terminal-mode
  for _, k in ipairs({ "i", "a" }) do
    vim.keymap.set("n", k, function()
      vim.cmd("startinsert")
    end, { buffer = buf, silent = true, desc = "ave: 回到 agent 输入" })
  end
end

-- 测试用：按一次键（走和 keymap 同一个函数）
function M.__test_key(key)
  local fn = term_keys[key]
  if not fn then
    return false
  end
  fn()
  return true
end

function M.open(spec)
  if M.is_open() then
    return state.win, state.buf, state.job
  end
  local cols = vim.o.columns
  local width = math.max(20, math.floor(cols * (spec.width or 0.25)))
  if not valid_win(state.win) then
    local prev = vim.api.nvim_get_current_win()
    vim.cmd("botright " .. width .. "vsplit")
    state.win = vim.api.nvim_get_current_win()
    -- vsplit 触发的 WinEnter 会把新窗口记成工作窗口，这里纠正回原窗口
    if valid_win(prev) and prev ~= state.win then
      state.work_win = prev
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.win, buf)
  vim.api.nvim_win_set_width(state.win, width)
  vim.wo[state.win].number = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].winfixwidth = true

  local job = vim.fn.jobstart(spec.cmd, {
    term = true,
    cwd = spec.cwd,
    -- 空 table 会被当成 list，E475
    env = (spec.env and next(spec.env)) and spec.env or nil,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          vim.notify("ave: agent exited with " .. tostring(code), vim.log.levels.WARN)
        end
        if state.buf == buf then
          M.close()
        end
      end)
    end,
  })
  if job <= 0 then
    vim.api.nvim_buf_delete(buf, { force = true })
    return nil, "failed to start: " .. table.concat(spec.cmd, " ")
  end
  state.buf, state.job = buf, job
  vim.bo[buf].filetype = "ave-agent"
  M.map_term(buf, job, spec)
  if not spec.focus then
    vim.api.nvim_set_current_win(M.work_win())
  end
  return state.win, state.buf, state.job
end

-- 测试用：只装状态，不起进程
function M.__test_attach(buf, work_win, job, win)
  state.buf, state.job, state.work_win = buf, job or -1, work_win
  state.win = win or vim.api.nvim_get_current_win()
end

function M.__test_detach()
  state.buf, state.job, state.win, state.work_win, state.full_tab = nil, nil, nil, nil, nil
end

function M.close()
  -- 关自己触发 on_exit 时不要再进来一次
  if state.closing then
    return
  end
  state.closing = true
  if state.full_tab and vim.api.nvim_tabpage_is_valid(state.full_tab) then
    pcall(vim.api.nvim_set_current_tabpage, state.full_tab)
    pcall(vim.cmd, "tabclose")
  end
  state.full_tab = nil
  if state.job then
    pcall(vim.fn.jobstop, state.job)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  if valid_win(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.job, state.buf, state.win = nil, nil, nil
  state.closing = false
end

-- 全屏：把面板 buffer 扔进独立 tab，不动原来的分屏布局；再切回来就行
function M.toggle_full()
  if not M.is_open() then
    return nil, "agent is not running"
  end
  if state.full_tab and vim.api.nvim_tabpage_is_valid(state.full_tab) then
    pcall(vim.api.nvim_set_current_tabpage, state.full_tab)
    pcall(vim.cmd, "tabclose")
    state.full_tab = nil
    return false
  end
  vim.cmd("tab sbuffer " .. state.buf)
  state.full_tab = vim.api.nvim_get_current_tabpage()
  vim.wo.number = false
  vim.wo.signcolumn = "no"
  vim.cmd("startinsert")
  return true
end

function M.is_full()
  return state.full_tab ~= nil and vim.api.nvim_tabpage_is_valid(state.full_tab)
end

-- 往 agent 终端粘文本（不回车）：用户主动把选区送给 agent 时用
function M.send(text)
  if not state.job then
    return nil, "agent is not running"
  end
  vim.fn.chansend(state.job, text)
  return true
end

function M.focus()
  if valid_win(state.win) then
    vim.api.nvim_set_current_win(state.win)
  end
end

function M.back()
  vim.api.nvim_set_current_win(M.work_win())
end

return M
