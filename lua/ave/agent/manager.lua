local M = {}

local st = require("ave.state")

function M.start(name)
  local cfg = require("ave.config")
  local opts = cfg.get()
  name = name or opts.agent
  -- 单面板：换 agent 前先收掉旧的，否则旧进程变孤儿
  if M.is_running() then
    M.stop()
  end
  local ok, err = require("ave.bridge").ensure()
  if not ok then
    return nil, err
  end
  local adapter = require("ave.agent.adapters").get(name)
  if not adapter then
    return nil, "unknown agent: " .. tostring(name)
  end
  local sess = st.new_session(name)
  local spec, serr = adapter.spec(sess, opts)
  if not spec then
    st.stop_session(sess)
    return nil, serr
  end
  spec.env = vim.tbl_extend("force", {
    WORKBENCH_SOCKET = sess.socket,
    AVE_SESSION = tostring(sess.id),
    AVE_ROOT = sess.root,
  }, spec.env or {})
  spec.width = opts.width
  local win, buf, job = require("ave.ui.layout").open(spec)
  if not win then
    st.stop_session(sess)
    return nil, buf
  end
  sess.win, sess.buf, sess.job, sess.cleanup = win, buf, job, spec.cleanup
  st.current = sess
  return sess
end

function M.stop()
  local sess = st.current
  require("ave.ui.layout").close()
  if sess and sess.cleanup then
    pcall(sess.cleanup)
  end
  st.stop_session(sess)
end

function M.is_running()
  return require("ave.ui.layout").is_open()
end

function M.toggle()
  if M.is_running() then
    M.stop()
    return
  end
  return M.start()
end

return M
