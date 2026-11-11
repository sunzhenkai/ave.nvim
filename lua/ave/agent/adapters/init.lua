local M = {}

local function valid_name(name)
  return type(name) == "string" and name:match("^[%w_]+$") ~= nil
end

function M.get(name)
  if not valid_name(name) then
    return nil
  end
  local ok, mod = pcall(require, "ave.agent.adapters." .. name)
  if not ok then
    return nil
  end
  return mod
end

return M
