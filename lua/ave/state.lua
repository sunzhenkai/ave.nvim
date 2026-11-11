local M = {
  id = 0,
  sessions = {},
  current = nil,
  server = nil,
  socket = nil,
  root = nil,
}

function M.socket_path()
  local dir = require("ave.config").get().socket_dir
  if not dir then
    local run = vim.env.XDG_RUNTIME_DIR
    dir = run and (run .. "/ave") or (vim.fn.stdpath("run") .. "/ave")
  end
  vim.fn.mkdir(dir, "p", "0700")
  return dir .. "/" .. vim.fn.getpid() .. ".sock"
end

function M.new_session(agent)
  M.id = M.id + 1
  local sess = {
    id = M.id,
    agent = agent,
    root = M.root or vim.fn.getcwd(),
    socket = M.socket,
  }
  M.sessions[sess.id] = sess
  return sess
end

function M.stop_session(sess)
  if sess then
    M.sessions[sess.id] = nil
  end
  if M.current == sess then
    M.current = nil
  end
end

return M
