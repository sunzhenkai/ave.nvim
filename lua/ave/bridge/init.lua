local M = {}

local st = require("ave.state")

function M.ensure()
  if st.server then
    return true
  end
  local path = st.socket_path()
  st.socket = path
  st.root = vim.fn.getcwd()
  local server = require("ave.bridge.server").new(path, require("ave.bridge.router"))
  local ok, err = server:start()
  if not ok then
    st.socket = nil
    return nil, err
  end
  st.server = server
  return true
end

function M.stop()
  if st.server then
    st.server:stop()
    st.server = nil
  end
end

return M
