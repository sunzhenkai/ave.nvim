-- 业务逻辑导览：agent 一次性给出排好序的跳转块，人按块走，不走回头路
local M = {}

local st = require("ave.state")
local ns = vim.api.nvim_create_namespace("ave_note")

M.list, M.idx, M.title = {}, 0, nil
local pinned

function M.active()
  return #M.list > 0
end

-- 解释贴在目标行上方；换块、换 buffer 都要清掉，否则旧标注会留在别人文件里
local function pin(res, note)
  if pinned and vim.api.nvim_buf_is_valid(pinned) then
    vim.api.nvim_buf_clear_namespace(pinned, ns, 0, -1)
  end
  pinned = nil
  if not note or note == "" then
    return
  end
  local buf = vim.fn.bufnr(res.file)
  if buf < 1 then
    return
  end
  local lines = vim.split(note, "\n", { plain = true })
  local virt = {}
  for i, line in ipairs(lines) do
    virt[#virt + 1] = { { (i == 1 and "▸ " or "  ") .. line, "Comment" } }
  end
  vim.api.nvim_buf_set_extmark(buf, ns, math.max(0, res.line - 1), 0, {
    virt_lines = virt,
    virt_lines_above = true,
  })
  pinned = buf
end

function M.goto(i)
  i = tonumber(i) or M.idx
  if i < 1 or i > #M.list then
    return nil, ("block %s out of range 1..%d"):format(tostring(i), #M.list)
  end
  local b = M.list[i]
  local res, err = require("ave.editor").open({
    file = b.file,
    line = b.line,
    end_line = b.end_line,
    from_path = true,
  })
  if not res then
    return nil, err
  end
  M.idx = i
  pin(res, b.note)
  M.sync()
  return { index = i, total = #M.list, file = res.file or b.file, line = res.line, note = b.note }
end

-- 列表窗口（lopen 开的那个），没有就 nil
local function qf_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "quickfix" then
      return w
    end
  end
end

-- 用户在列表里把光标挪到某一行，就把它当成当前位置
function M.selected()
  local w = qf_win()
  if not w then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(w)[1]
  if row >= 1 and row <= #M.list then
    return row
  end
end

function M.step(delta)
  if not M.active() then
    return nil, "no tour (agent has not sent one)"
  end
  local n = (M.selected() or M.idx) + delta
  if n < 1 then
    return nil, "already at the first block"
  end
  if n > #M.list then
    return nil, "already at the last block"
  end
  return M.goto(n)
end

-- append: agent 分几次给块时接着往后排，不从头开始
function M.set(blocks, title, append)
  local list = append and M.active() and vim.deepcopy(M.list) or {}
  local seen = {}
  for _, b in ipairs(list) do
    seen[b.file .. ":" .. b.line] = true
  end
  for i, b in ipairs(blocks or {}) do
    local path = require("ave.editor").resolve(b.file)
    if not path then
      return nil, ("block %d: file is required"):format(i)
    end
    local key = path .. ":" .. (b.line or 1)
    if seen[key] then
      goto continue
    end
    seen[key] = true
    list[#list + 1] = {
      index = #list + 1,
      file = path,
      line = b.line or 1,
      end_line = b.end_line,
      note = b.note or b.title,
    }
    ::continue::
  end
  if #list == 0 then
    return nil, "blocks is empty"
  end
  if append and M.active() then
    M.list = list
    M.title = M.title or title
    M.show()
    return { title = M.title, count = #list, current = { index = M.idx, total = #list } }
  end
  M.list, M.idx, M.title = list, 1, title
  M.show()
  local res, err = M.goto(1)
  if not res then
    return nil, err
  end
  return { title = title, count = #list, current = res }
end

function M.clear()
  M.list, M.idx, M.title = {}, 0, nil
  if pinned and vim.api.nvim_buf_is_valid(pinned) then
    vim.api.nvim_buf_clear_namespace(pinned, ns, 0, -1)
  end
  pinned = nil
  -- loclist 是窗口级的、窗口可能已被关掉，按 title 找回自己那份清
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local title = vim.fn.getloclist(w, { title = 0 }).title or ""
    if title:match("^ave tour") then
      vim.api.nvim_win_call(w, function()
        if vim.fn.getloclist(0, { winid = 0 }).winid ~= 0 then
          pcall(vim.cmd, "lclose")
        end
        pcall(vim.fn.setloclist, 0, {}, "r", { title = "", items = {} })
      end)
    end
  end
  M.win = nil
  return true
end

local NAME_W = 34

-- 路径太长会把描述挤没：中间省略成 …，再补空格让所有行等宽
local function shortpath(rel)
  if #rel > NAME_W then
    local dir, base = rel:match("^(.*)/([^/]+)$")
    if dir and #base + 4 < NAME_W then
      rel = dir:sub(1, NAME_W - #base - 4) .. "…/" .. base
    else
      rel = "…" .. rel:sub(-(NAME_W - 1))
    end
  end
  return rel .. string.rep(" ", NAME_W - #rel)
end

-- 列表行：▶ 标当前块，描述放最后
function M.items()
  local root = st.root or vim.fn.getcwd()
  local items = {}
  for _, b in ipairs(M.list) do
    local where = ("[%d] L%d"):format(b.index, b.line)
    if b.end_line and b.end_line > b.line then
      where = where .. ("-%d"):format(b.end_line)
    end
    items[#items + 1] = {
      filename = shortpath(vim.fs.relpath(root, b.file) or b.file),
      lnum = b.line,
      text = (b.index == M.idx and "▶ " or "  ") .. where .. "  " .. (b.note or ""):gsub("\n", " "),
    }
  end
  return items
end

-- 列表窗口里的回车必须先被我们接住，原生跳转不会打 extmark、也不联动
local function map_list_keys()
  local qbuf = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "quickfix" then
      qbuf = vim.api.nvim_win_get_buf(w)
    end
  end
  if not qbuf or vim.b[qbuf].ave_tour_keys then
    return
  end
  vim.b[qbuf].ave_tour_keys = true
  for _, key in ipairs({ "<CR>", "o" }) do
    vim.api.nvim_buf_set_keymap(qbuf, "n", key, "", {
      nowait = true,
      silent = true,
      callback = function()
        M.enter()
      end,
    })
  end
end

-- 在列表里回车：走 M.goto 才能拿到高亮和 ▶ 联动，原生跳转不会打 extmark
function M.enter()
  if vim.bo.buftype ~= "quickfix" then
    return nil, "not in the tour list"
  end
  local i = vim.fn.line(".")
  vim.api.nvim_set_current_win(M.win)
  return M.goto(i)
end

-- 跳块后同步列表里的 ▶ 标记，不重开窗口
function M.sync()
  local win = M.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  vim.api.nvim_win_call(win, function()
    vim.fn.setloclist(0, {}, "r", { title = "ave tour" .. (M.title and (" · " .. M.title) or ""), items = M.items() })
  end)
  map_list_keys()
  -- 列表选中行跟着当前块走（setloclist 会把 qf 光标弹回第一行）
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "quickfix" then
      pcall(vim.api.nvim_win_set_cursor, w, { M.idx, 0 })
    end
  end
end

function M.show()
  if not M.active() then
    return nil, "no tour"
  end
  local items = M.items()
  -- 列表挂在代码窗口上（loclist 是窗口级的），不然切窗口就看丢了
  local work = require("ave.ui.layout").work_win()
  if not (work and vim.api.nvim_win_is_valid(work)) then
    work = vim.api.nvim_get_current_win()
  end
  M.win = work
  vim.api.nvim_win_call(work, function()
    -- title 固定前缀，clear 靠它找回自己的 loclist
    vim.fn.setloclist(0, {}, " ", {
      title = "ave tour" .. (M.title and (" · " .. M.title) or ""),
      items = items,
    })
    vim.cmd("lopen")
  end)
  -- lopen 会把焦点拽到列表里；焦点还给代码窗口，列表只作参考
  vim.api.nvim_set_current_win(work)
  map_list_keys()
  return { count = #items, index = M.idx }
end

return M
