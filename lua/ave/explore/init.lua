-- 探索路径栈：agent 每跳一次压栈，用户沿路径前后走
local M = {}

M.stack = {}
M.idx = 0

local function entry_of(p, res)
  return {
    file = res.file,
    line = res.line,
    end_line = res.end_line,
    title = p.title,
  }
end

function M.push(p, res)
  local e = entry_of(p, res)
  local cur = M.stack[M.idx]
  if cur and cur.file == e.file and cur.line == e.line then
    -- 同一处反复打开不重复压栈
    M.stack[M.idx] = e
    return
  end
  -- 回退后再跳，丢弃原来的前向分支
  for i = #M.stack, M.idx + 1, -1 do
    table.remove(M.stack, i)
  end
  M.stack[#M.stack + 1] = e
  M.idx = #M.stack
end

function M.current()
  return M.stack[M.idx]
end

function M.entries()
  return M.stack, M.idx
end

function M.reset()
  M.stack, M.idx = {}, 0
end

local function jump(e)
  return function()
    require("ave.editor").open({
      file = e.file,
      line = e.line,
      end_line = e.end_line,
      from_path = true,
      focus = true,
    })
    return { ok = true, index = M.idx, total = #M.stack, file = e.file, line = e.line }
  end
end

function M.goto(i)
  if i < 1 or i > #M.stack then
    return nil, ("index out of range: %d (1..%d)"):format(i, #M.stack)
  end
  M.idx = i
  return jump(M.stack[i])()
end

function M.back()
  if M.idx <= 1 then
    return nil, "already at the first step"
  end
  return M.goto(M.idx - 1)
end

function M.forward()
  if M.idx >= #M.stack then
    return nil, "already at the last step"
  end
  return M.goto(M.idx + 1)
end

function M.loclist()
  if #M.stack == 0 then
    return nil, "path is empty"
  end
  local items = {}
  for i, e in ipairs(M.stack) do
    items[i] = {
      filename = e.file,
      lnum = e.line,
      end_lnum = e.end_line,
      text = (e.title and (e.title .. " ") or "") .. (i == M.idx and "[current]" or ""),
    }
  end
  vim.fn.setloclist(0, {}, "r", { title = "ave path", items = items })
  vim.cmd("lopen")
  return { ok = true, total = #M.stack, index = M.idx }
end

return M
