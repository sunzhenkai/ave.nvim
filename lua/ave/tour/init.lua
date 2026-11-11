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
  return { index = i, total = #M.list, file = res.file or b.file, line = res.line, note = b.note }
end

function M.step(delta)
  if not M.active() then
    return nil, "no tour (agent has not sent one)"
  end
  local n = M.idx + delta
  if n < 1 then
    return nil, "already at the first block"
  end
  if n > #M.list then
    return nil, "already at the last block"
  end
  return M.goto(n)
end

function M.set(blocks, title)
  local list = {}
  for i, b in ipairs(blocks or {}) do
    local path = require("ave.editor").resolve(b.file)
    if not path then
      return nil, ("block %d: file is required"):format(i)
    end
    list[#list + 1] = {
      index = #list + 1,
      file = path,
      line = b.line or 1,
      end_line = b.end_line,
      note = b.note or b.title,
    }
  end
  if #list == 0 then
    return nil, "blocks is empty"
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
      break
    end
  end
  M.win = nil
  return true
end

function M.show()
  if not M.active() then
    return nil, "no tour"
  end
  local root = st.root or vim.fn.getcwd()
  local items = {}
  for _, b in ipairs(M.list) do
    items[#items + 1] = {
      filename = vim.fs.relpath(root, b.file) or b.file,
      lnum = b.line,
      text = ("[%d] %s"):format(b.index, (b.note or ""):gsub("\n", " ")),
    }
  end
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
  -- lopen 会把焦点拽到列表里；光标留在代码上，列表只是参考
  vim.api.nvim_set_current_win(work)
  return { count = #items, index = M.idx }
end

return M
