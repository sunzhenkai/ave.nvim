-- 方法白名单。桥不暴露任意 Lua 执行。
local M = {}

local handlers = {}

local function define(name, fn)
  handlers[name] = fn
end

define("ping", function()
  return { ok = true, pid = vim.fn.getpid(), version = "0.1.0" }
end)

define("editor.context", function()
  return require("ave.editor").context()
end)

define("editor.open", function(p)
  local res, err = require("ave.editor").open(p)
  if not res then
    error(err or "open failed", 0)
  end
  return res
end)

define("editor.highlight", function(p)
  local res, err = require("ave.editor").highlight(p)
  if not res then
    error(err or "highlight failed", 0)
  end
  return res
end)

define("explore.path", function()
  local stack, idx = require("ave.explore").entries()
  return { index = idx, total = #stack, entries = stack }
end)

for _, mode in ipairs({ "back", "forward" }) do
  define("explore." .. mode, function()
    local res, err = require("ave.explore")[mode]()
    if not res then
      error(err or (mode .. " failed"), 0)
    end
    return res
  end)
end

function M.handle(method, params)
  local h = handlers[method]
  if not h then
    return nil, { code = -32601, message = "unknown method: " .. tostring(method) }
  end
  local ok, res = pcall(h, params or {})
  if not ok then
    return nil, { code = -32603, message = tostring(res) }
  end
  return res
end

function M.methods()
  local t = {}
  for k in pairs(handlers) do
    t[#t + 1] = k
  end
  table.sort(t)
  return t
end

M.define = define

return M
