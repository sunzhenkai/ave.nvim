// 走 MCP stdio → helper → UDS → nvim，验证真链接
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const socket = process.env.WORKBENCH_SOCKET;
const helper = process.env.AVE_HELPER;
const root = process.cwd();

let fails = 0;
const check = (name, cond, detail) => {
  if (cond) console.log("ok   " + name);
  else {
    fails++;
    console.log("FAIL " + name + (detail === undefined ? "" : " -> " + JSON.stringify(detail)));
  }
};

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [helper, "mcp"],
  env: { ...process.env, WORKBENCH_SOCKET: socket },
});
const client = new Client({ name: "ave-e2e", version: "0" });
await client.connect(transport);

const call = async (name, args = {}) => {
  const res = await client.callTool({ name, arguments: args });
  const text = res.content?.[0]?.text ?? "";
  return { text, isError: !!res.isError, json: (() => { try { return JSON.parse(text); } catch { return null; } })() };
};

const ping = await call("editor_context");
check("editor_context answers", ping.isError === false && ping.json?.root === root, ping.text.slice(0, 120));

const open = await call("editor_open", { file: "lua/ave/config.lua", line: 99, snippet: "M.options = vim.deepcopy" });
check("snippet corrects line", open.json?.stale === undefined && open.json?.line > 1, open.json);

const stale = await call("editor_open", { file: "lua/ave/config.lua", line: 1, snippet: "根本不存在的代码" });
check("stale is reported", stale.json?.stale === true, stale.json);

await call("editor_open", { file: "lua/ave/state.lua", line: 2 });
const list = await call("explore_path", { mode: "list" });
check("path has hops", list.json?.total >= 2, list.json);

const back = await call("explore_path", { mode: "back" });
check("back returns earlier hop", back.json?.index === list.json.total - 1, back.json);

const def = await call("editor_lsp", { kind: "definition", file: "tests/lsp_fixture/b.c", line: 4, column: 10 });
check("lsp definition finds target", (def.json?.items ?? []).some((i) => i.line === 1) && def.json?.count > 0, def.json ?? def.text);

const refs = await call("editor_lsp", { kind: "references", file: "tests/lsp_fixture/a.c", line: 1, column: 5 });
check("lsp references find call site", (refs.json?.items ?? []).some((i) => i.file.endsWith("b.c")), refs.json ?? refs.text);

const tour = await call("editor_tour", {
  title: "自检导览",
  blocks: [
    { file: "lua/ave/config.lua", line: 5, note: "默认配置" },
    { file: "lua/ave/state.lua", line: 10, note: "socket 路径" },
  ],
});
check("tour installs blocks", tour.json?.count === 2 && tour.json?.current?.index === 1, tour.json ?? tour.text);

const prev = await call("explore_path", { mode: "list" });
check("tour leaves explore path alone", prev.json?.total >= 2, prev.json);

const bad = await call("editor_lsp", { kind: "nope" });
check("lsp rejects unknown kind", bad.isError === true, bad.text);

// 没带 WORKBENCH_SOCKET（agent 从终端起）时自己找桥：用临时 XDG 目录围起来，免得碰到用户的 nvim
const disc = mkdtempSync(join(tmpdir(), "ave-disc-"));
mkdirSync(join(disc, "ave"), { recursive: true });
symlinkSync(socket, join(disc, "ave", "x.sock"));
const bare = { ...process.env, XDG_RUNTIME_DIR: disc, XDG_STATE_HOME: join(disc, "state") };
delete bare.WORKBENCH_SOCKET;
const found = spawnSync(process.execPath, [helper, "ping"], { env: bare, encoding: "utf8" });
check("discovers socket without env", found.status === 0 && /"ok":true/.test(found.stdout), found.stdout + found.stderr);

const empty = await spawnSync(process.execPath, [helper, "ping"], {
  env: { ...bare, XDG_RUNTIME_DIR: join(disc, "none") },
  encoding: "utf8",
});
check("reports missing bridge", empty.status === 1 && /没找到 ave 桥/.test(empty.stderr), empty.stderr);

await client.close();
console.log(fails === 0 ? "ALL PASS" : "FAILED " + fails);
process.exit(fails === 0 ? 0 : 1);
