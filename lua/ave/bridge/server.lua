-- nvim 内 UDS 服务：NDJSON + JSON-RPC 2.0
local M = {}
local uv = vim.uv or vim.loop

local Server = {}
Server.__index = Server

function M.new(path, router)
  return setmetatable({ path = path, router = router, conns = {}, pipe = nil }, Server)
end

function Server:start()
  if self.pipe then
    return true
  end
  if uv.fs_stat(self.path) then
    uv.fs_unlink(self.path)
  end
  local pipe = uv.new_pipe(false)
  local ok, err = pipe:bind(self.path)
  if not ok then
    return nil, err
  end
  -- bind 后默认 0755，同机其他用户可连；LuaJIT 无 0o 字面量
  uv.fs_chmod(self.path, tonumber("600", 8))
  pipe:listen(16, function(err)
    if not err then
      self:_accept()
    end
  end)
  self.pipe = pipe
  return true
end

function Server:_accept()
  local conn = uv.new_pipe(false)
  self.pipe:accept(conn)
  if not conn then
    return
  end
  self.conns[conn] = true
  local buf = ""

  -- fast event context: 只拼包解帧，编辑器操作丢给主循环
  conn:read_start(function(err, data)
    if err or not data then
      self.conns[conn] = nil
      conn:close()
      return
    end
    buf = buf .. data
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = buf:sub(1, nl - 1):gsub("\r$", "")
      buf = buf:sub(nl + 1)
      if line ~= "" then
        local okj, msg = pcall(vim.json.decode, line)
        vim.schedule(function()
          self:_handle(conn, okj and msg or nil, line)
        end)
      end
    end
  end)
end

function Server:_handle(conn, msg, raw)
  if type(msg) ~= "table" then
    return self:_send(conn, {
      jsonrpc = "2.0",
      id = nil,
      error = { code = -32700, message = "parse error", data = raw },
    })
  end
  local result, err = self.router.handle(msg.method, msg.params)
  if msg.id == nil then
    return -- notification
  end
  if err then
    return self:_send(conn, { jsonrpc = "2.0", id = msg.id, error = err })
  end
  self:_send(conn, { jsonrpc = "2.0", id = msg.id, result = result })
end

function Server:_send(conn, obj)
  if not conn or conn:is_closing() then
    return
  end
  conn:write(vim.json.encode(obj) .. "\n")
end

function Server:stop()
  for conn in pairs(self.conns) do
    if not conn:is_closing() then
      conn:close()
    end
  end
  self.conns = {}
  if self.pipe then
    self.pipe:close()
    self.pipe = nil
    uv.fs_unlink(self.path)
  end
end

return M
