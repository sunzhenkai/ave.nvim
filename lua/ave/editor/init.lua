-- 编辑器侧能力：上下文、跳转、高亮
local M = {}

local ns = vim.api.nvim_create_namespace("ave_explore")

local function root()
  return require("ave.state").root or vim.fn.getcwd()
end

function M.resolve(file)
  if type(file) ~= "string" or file == "" then
    return nil
  end
  if file:sub(1, 1) == "~" then
    return vim.fs.normalize(vim.fn.expand(file))
  end
  if file:sub(1, 1) == "/" then
    return vim.fs.normalize(file)
  end
  return vim.fs.normalize(root() .. "/" .. file)
end

function M.find_snippet(buf, snippet, near)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local first
  for i, l in ipairs(lines) do
    if l:find(snippet, 1, true) then
      if not first then
        first = i
      end
      if math.abs(i - (near or 0)) <= 3 then
        return i
      end
    end
  end
  return first
end

function M.context()
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local path = vim.api.nvim_buf_get_name(buf)
  local cur = vim.api.nvim_win_get_cursor(win)
  local ctx = {
    root = root(),
    file = path ~= "" and path or nil,
    path = path ~= "" and vim.fs.relpath(root(), path) or nil,
    line = cur[1],
    column = cur[2] + 1,
    line_text = vim.api.nvim_buf_get_lines(buf, cur[1] - 1, cur[1], false)[1],
    filetype = vim.bo[buf].filetype,
    modified = vim.bo[buf].modified,
    mode = vim.fn.mode(),
  }
  local s = vim.api.nvim_buf_get_mark(buf, "<")
  local e = vim.api.nvim_buf_get_mark(buf, ">")
  if s[1] > 0 and e[1] >= s[1] then
    ctx.selection = {
      start_line = s[1],
      end_line = e[1],
      text = table.concat(vim.api.nvim_buf_get_lines(buf, s[1] - 1, e[1], false), "\n"),
    }
  end
  return ctx
end

function M.mark(buf, start_line, end_line)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, start_line - 1, 0, {
    end_row = end_line,
    end_col = 0,
    hl_group = "Visual",
  })
end

function M.open(p)
  local path = M.resolve(p.file)
  if not path then
    return nil, "file is required"
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local want = tonumber(p.line) or 1
  local line, stale = want, nil
  if p.snippet and p.snippet ~= "" then
    local found = M.find_snippet(buf, p.snippet, want)
    if found then
      line = found
    else
      stale = true
    end
  end
  line = math.min(math.max(line, 1), vim.api.nvim_buf_line_count(buf))
  local end_line = tonumber(p.end_line)
  if end_line then
    end_line = end_line + (line - want)
  end
  local win = require("ave.ui.layout").work_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  if p.focus then
    vim.api.nvim_set_current_win(win)
  end
  M.mark(buf, line, math.max(line, end_line or line))
  return { ok = true, file = path, line = line, end_line = end_line, stale = stale or nil }
end

function M.highlight(p)
  local path = M.resolve(p.file or vim.api.nvim_buf_get_name(0))
  if not path then
    return nil, "file is required"
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local start_line = math.max(tonumber(p.start_line) or 1, 1)
  local end_line = math.max(tonumber(p.end_line) or start_line, start_line)
  M.mark(buf, start_line, end_line)
  return { ok = true, file = path, start_line = start_line, end_line = end_line }
end

return M
