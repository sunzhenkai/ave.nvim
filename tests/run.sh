#!/usr/bin/env bash
# 需要：nvim 带 UI（pty）、node、mason 里的 pyright-langserver
set -uo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)
fails=0

echo "== 单元级（无 bridge） =="
rm -f /tmp/ave-test-unit.log
timeout 60 script -qfc "nvim --clean -c 'luafile tests/e2e.lua'" /tmp/ave-test-unit.log >/dev/null 2>&1 || true
tr -d '\r' < /tmp/ave-test-unit.log | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b(B//g' | grep -aE "^(ok|FAIL|ALL PASS|FAILED)" || true
grep -aq "ALL PASS" /tmp/ave-test-unit.log || fails=$((fails + 1))

echo "== 端到端（MCP → helper → UDS → nvim） =="
rm -f /tmp/ave-mcp-e2e.sock /tmp/ave-mcp-e2e.err /tmp/ave-test-host.log
# 测试用自己的运行时目录：默认目录里可能有正在用的编辑器 socket，删了会断掉它的桥
export XDG_RUNTIME_DIR=/tmp/ave-test-runtime
rm -rf "$XDG_RUNTIME_DIR" && mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
# swap/log 也隔离：残留的 swap 会让 nvim 卡在 "Press ENTER"
export XDG_STATE_HOME=/tmp/ave-test-state
rm -rf "$XDG_STATE_HOME" && mkdir -p "$XDG_STATE_HOME"
timeout 60 script -qfc "nvim --clean -c 'luafile tests/host.lua'" /tmp/ave-test-host.log >/dev/null 2>&1 &
host_pid=$!
for _ in $(seq 1 40); do
  [ -s /tmp/ave-mcp-e2e.sock ] && break
  sleep 0.5
done
if [ ! -s /tmp/ave-mcp-e2e.sock ]; then
  echo "FAIL host did not publish socket"
  cat /tmp/ave-mcp-e2e.err 2>/dev/null
  kill "$host_pid" 2>/dev/null
  exit 1
fi
WORKBENCH_SOCKET=$(cat /tmp/ave-mcp-e2e.sock) AVE_HELPER="$root/bridge-helper/index.mjs" \
  node bridge-helper/test/e2e.mjs
[ $? -eq 0 ] || fails=$((fails + 1))
kill "$host_pid" 2>/dev/null
wait "$host_pid" 2>/dev/null

if [ "$fails" -ne 0 ]; then
  echo "RESULT: FAILED ($fails suite(s))"
  exit 1
fi
echo "RESULT: PASS"
