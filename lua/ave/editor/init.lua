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

-- 让整块落在视野中间；块比窗口高时把它顶到第一行，避免只看得到尾巴
function M.center_block(win, first, last)
  local height = vim.api.nvim_win_get_height(win)
  local span = last - first + 1
  local target = (span >= height) and first or (first + math.floor((span - 1) / 2))
  vim.api.nvim_win_set_cursor(win, { target, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd(span >= height and "normal! zt" or "normal! zz")
  end)
  vim.api.nvim_win_set_cursor(win, { first, 0 })
end

function M.open(p)
  local path = M.resolve(p.file)
  if not path then
    return nil, "file is required"
  end
  local buf = vim.fn.bufadd(path)
  M.navigating = true
  vim.fn.bufload(buf)
  M.navigating = false
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
  -- 跳转前记进窗口的 jumplist，用户可以用 <C-o> 回来
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) ~= path then
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd("normal! m'")
    end)
  end
  vim.api.nvim_win_set_buf(win, buf)
  M.center_block(win, line, math.max(line, end_line or line))
  if p.focus then
    vim.api.nvim_set_current_win(win)
  end
  M.mark(buf, line, math.max(line, end_line or line))
  if not p.from_path then
    require("ave.explore").push(p, { file = path, line = line, end_line = end_line })
  end
  return { ok = true, file = path, line = line, end_line = end_line, stale = stale or nil }
end

local LSP_METHODS = {
  definition = "textDocument/definition",
  references = "textDocument/references",
  symbols = "textDocument/documentSymbol",
  implementations = "textDocument/implementation",
}

-- Location / LocationLink / DocumentSymbol 都收成 {file, line, ...}
local function location_items(result, out, default_file)
  if type(result) ~= "table" then
    return
  end
  for _, item in pairs(result) do
    local uri = item.uri or item.targetUri
    local range = item.range or item.targetSelectionRange or item.targetRange
    if uri and range then
      out[#out + 1] = {
        file = vim.uri_to_fname(uri),
        line = range.start.line + 1,
        column = range.start.character + 1,
        end_line = range["end"].line + 1,
      }
    elseif item.name then
      local r = item.selectionRange or item.range
      local file = (item.location and item.location.uri and vim.uri_to_fname(item.location.uri)) or default_file
      if r then
        out[#out + 1] = { file = file, line = r.start.line + 1, name = item.name, kind = item.kind }
      end
    end
  end
end

function M.lsp(p)
  local kind = p.kind or "definition"
  local method = LSP_METHODS[kind]
  if not method then
    return nil, "unknown kind: " .. tostring(kind) .. " (definition|references|symbols|implementations)"
  end
  local buf = vim.api.nvim_get_current_buf()
  if p.file then
    local path = M.resolve(p.file)
    if not path then
      return nil, "file is required"
    end
    buf = vim.fn.bufadd(path)
    M.navigating = true
    vim.fn.bufload(buf)
    M.navigating = false
    if vim.bo[buf].filetype == "" then
      vim.bo[buf].filetype = vim.filetype.match({ filename = path }) or ""
    end
  end
  local line, col = p.line, p.column
  if not line then
    local cur = vim.api.nvim_win_get_cursor(0)
    line, col = cur[1], cur[2] + 1
  end
  -- 目标 buffer 可能还没挂 client（bufadd 出来的），退回到当前 buffer 的 client：
  -- 请求按 URI 定位文档，只要文件在磁盘上就能查
  local clients = vim.lsp.get_clients({ bufnr = buf })
  if #clients == 0 then
    clients = vim.lsp.get_clients()
  end
  if #clients == 0 then
    return nil, "no LSP client attached to " .. vim.api.nvim_buf_get_name(buf) .. " (fall back to search)"
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = (line or 1) - 1, character = (col or 1) - 1 },
  }
  if kind == "references" then
    params.context = { includeDeclaration = true }
  end
  -- 目标 buffer 没挂 client 时补挂：否则 server 没收到 didOpen，references 这类
  -- 需要已解析文件的请求会返回空
  for _, c in ipairs(clients) do
    if not vim.lsp.buf_is_attached(buf, c.id) then
      pcall(vim.lsp.buf_attach_client, buf, c.id)
    end
  end
  local results, pending = {}, #clients
  for _, c in ipairs(clients) do
    c:request(method, params, function(_, result)
      results[c.id] = result
      pending = pending - 1
    end)
  end
  vim.wait(3000, function()
    return pending <= 0
  end)
  local out = {}
  for _, result in pairs(results) do
    location_items(result, out, vim.api.nvim_buf_get_name(buf))
  end
  local limit = p.limit or 50
  local truncated = #out > limit
  while #out > limit do
    table.remove(out)
  end
  return { ok = true, kind = kind, count = #out, truncated = truncated or nil, items = out }
end

function M.highlight(p)
  local path = M.resolve(p.file or vim.api.nvim_buf_get_name(0))
  if not path then
    return nil, "file is required"
  end
  local buf = vim.fn.bufadd(path)
  M.navigating = true
  vim.fn.bufload(buf)
  M.navigating = false
  local start_line = math.max(tonumber(p.start_line) or 1, 1)
  local end_line = math.max(tonumber(p.end_line) or start_line, start_line)
  M.mark(buf, start_line, end_line)
  return { ok = true, file = path, start_line = start_line, end_line = end_line }
end

return M
