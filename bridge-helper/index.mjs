#!/usr/bin/env node
// ave bridge helper: MCP stdio server + Neovim UDS client.
// 子命令 `ping` / `call <method> [json]` 用于无 agent 时手工排查链路。
import fs from "node:fs";
import net from "node:net";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

// 从 nvim 里 :Ave 起的 agent 带 WORKBENCH_SOCKET；从终端起的没带，靠自己找
const pinned = process.env.WORKBENCH_SOCKET;
let socketPath = pinned ?? null;
const DEFAULT_TIMEOUT_MS = 5000;

let seq = 0;
let conn = null;
let buf = "";
const pending = new Map();

function socket_dirs() {
  const dirs = [];
  if (process.env.XDG_RUNTIME_DIR) dirs.push(process.env.XDG_RUNTIME_DIR + "/ave");
  const state = process.env.XDG_STATE_HOME || (process.env.HOME ? process.env.HOME + "/.local/state" : null);
  if (state) dirs.push(state + "/nvim/run/ave");
  return dirs;
}

function real(path) {
  try {
    return fs.realpathSync(path);
  } catch {
    return path;
  }
}

// 只有答得出 editor.context 的才算活桥，避免捡到 nvim 退出后残留的 sock 文件
function probe(path) {
  return new Promise((resolve) => {
    const c = net.createConnection(path);
    let b = "";
    const finish = (v) => {
      clearTimeout(timer);
      c.destroy();
      resolve(v);
    };
    const timer = setTimeout(() => finish(null), 400);
    c.setEncoding("utf8");
    c.once("error", () => finish(null));
    c.on("connect", () => c.write(JSON.stringify({ jsonrpc: "2.0", id: "probe", method: "editor.context", params: {} }) + "\n"));
    c.on("data", (chunk) => {
      b += chunk;
      const i = b.indexOf("\n");
      if (i < 0) return;
      try {
        finish(JSON.parse(b.slice(0, i)).result ?? null);
      } catch {
        finish(null);
      }
    });
  });
}

// 优先 cwd 与 nvim 根目录一致的实例；只有一个活的且对不上时才用它，多个就拒绝猜
async function discover() {
  const socks = [];
  for (const dir of socket_dirs()) {
    try {
      for (const f of fs.readdirSync(dir)) {
        if (f.endsWith(".sock")) socks.push(dir + "/" + f);
      }
    } catch {
      // 目录不存在：这台机没开过 ave
    }
  }
  const cwd = real(process.cwd());
  const alive = [];
  for (const path of socks.slice(0, 8)) {
    const ctx = await probe(path);
    if (!ctx?.root) continue;
    const root = real(ctx.root);
    if (root === cwd) return path;
    alive.push({ path, root });
  }
  const near = alive.find((a) => cwd.startsWith(a.root + "/"));
  if (near) return near.path;
  return alive.length === 1 ? alive[0].path : null;
}

async function ensureSocket() {
  if (socketPath) return socketPath;
  socketPath = await discover();
  if (!socketPath) {
    throw new Error(
      "没找到 ave 桥：从 nvim 执行 :Ave pi 启动，或设置 WORKBENCH_SOCKET（已扫 " + socket_dirs().join(", ") + "）",
    );
  }
  return socketPath;
}

async function connect() {
  if (conn) return conn;
  const path = await ensureSocket();
  return new Promise((resolve, reject) => {
    const c = net.createConnection(path);
    c.setEncoding("utf8");
    c.once("connect", () => {
      conn = c;
      resolve(c);
    });
    c.once("error", (e) => {
      // 发现的路径可能已被 nvim 重启换掉：下次调用重新找
      if (!pinned && socketPath === path) socketPath = null;
      reject(e);
    });
    c.on("data", (chunk) => {
      buf += chunk;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (!line) continue;
        let msg;
        try {
          msg = JSON.parse(line);
        } catch {
          continue;
        }
        const p = pending.get(msg.id);
        if (!p) continue;
        pending.delete(msg.id);
        if (msg.error) p.reject(new Error(msg.error.message ?? "bridge error"));
        else p.resolve(msg.result);
      }
    });
    c.on("close", () => {
      conn = null;
      buf = "";
      for (const p of pending.values()) p.reject(new Error("bridge disconnected"));
      pending.clear();
    });
  });
}

async function call(method, params = {}, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const c = await connect();
  const id = String(++seq);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${method} timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    pending.set(id, {
      resolve: (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      reject: (e) => {
        clearTimeout(timer);
        reject(e);
      },
    });
    c.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
}

const ok = (v) => ({ content: [{ type: "text", text: typeof v === "string" ? v : JSON.stringify(v, null, 2) }] });
const fail = (e) => ({ content: [{ type: "text", text: `ave bridge error: ${e.message ?? e}` }], isError: true });

async function run(method, params) {
  try {
    return ok(await call(method, params));
  } catch (e) {
    return fail(e);
  }
}

function readStdin() {
  return new Promise((resolve) => {
    let buf = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (c) => (buf += c));
    process.stdin.on("end", () => resolve(buf));
    process.stdin.on("error", () => resolve(buf));
  });
}

// Claude Code PostToolUse hook: 从工具调用里取文件，把编辑器跟着移过去。
// 任何失败都不输出、不阻塞 agent。
async function hook() {
  try {
    const raw = await readStdin();
    if (!raw.trim()) return;
    const ev = JSON.parse(raw);
    const input = ev.tool_input ?? {};
    const file = input.file_path ?? input.notebook_path;
    if (!file) return;
    const params = { file, focus: false };
    if (Number.isInteger(input.offset) && input.offset > 0) params.line = input.offset;
    else if (Number.isInteger(input.line)) params.line = input.line;
    await call("editor.open", params, 2000);
  } catch {
    // 桥没起来或 nvim 已退出：静默
  }
}

const [sub, a, b] = process.argv.slice(2);

if (sub === "hook") {
  await hook();
  process.exit(0);
} else if (sub === "call" || sub === "ping") {
  const method = sub === "ping" ? "ping" : a;
  const params = sub === "ping" ? {} : b ? JSON.parse(b) : {};
  try {
    process.stdout.write(JSON.stringify(await call(method, params)) + "\n");
    process.exit(0);
  } catch (e) {
    process.stderr.write(String(e.message ?? e) + "\n");
    process.exit(1);
  }
} else {
  const server = new McpServer(
    { name: "ave", version: "0.1.0" },
    {
      instructions: [
        "This server is attached to the user's Neovim session. Do not operate the editor by default: ordinary file reads, searches, edits, and multi-file analysis are not reasons to call editor_open or editor_tour.",
        "Prefer editor_lsp over grep when you need a definition or all references: it uses the language server the user already has.",
        "Call editor_context before answering questions about 'this file', 'the current selection', or 'where the user is'.",
        "Use editor_open only when the user asks to open, jump, or follow, or when the task clearly needs the editor's current position, selection, or code view. Pass snippet (one stable unique line of code) together with line; it survives edits and tells you when a line number went stale.",
        "Use editor_tour once only when the user asks for a walkthrough, or when a multi-file flow clearly benefits from reading ordered code blocks; a request to explain or summarize alone is not enough. Read first, then send the complete ordered list (file, line or line range, one or two sentences of explanation) instead of narrating each hop. Only if the list is too long for one call, append the remaining blocks.",
        "Explicit prohibitions take precedence: if the user says not to use ave, call no ave tools; if the user only forbids opening the editor or a walkthrough, avoid visible editor operations while read-only editor_context and editor_lsp remain allowed.",
        "Work off the files already on disk in the workspace on its current git branch: never copy them to a temp directory or check out another revision to make line numbers match, and mention the difference in a block's note instead.",
      ].join(" "),
    },
  );

  server.tool(
    "editor_context",
    "Current Neovim state: file, cursor, visual selection, filetype, workspace root, git branch.",
    {},
    () => run("editor.context", {}),
  );

  server.tool(
    "editor_open",
    "Open a file when the user asks for editor navigation or the task clearly needs the code view. Set focus=false (default) to keep the user's cursor where it is.",
    {
      file: z.string().describe("Absolute path, or path relative to the workspace root"),
      line: z.number().int().positive().optional().describe("1-based target line"),
      end_line: z.number().int().positive().optional().describe("1-based last line to highlight"),
      snippet: z.string().optional().describe("Stable code text expected on the target line; used to re-locate and detect staleness"),
      focus: z.boolean().optional().describe("Move the user's cursor into the target window"),
    },
    (args) => run("editor.open", args),
  );

  server.tool(
    "editor_lsp",
    "Ask the editor's language server instead of grepping: definition, references, implementations, or document symbols. Returns file/line items. Fails when no LSP client is attached, in which case fall back to plain search.",
    {
      kind: z.enum(["definition", "references", "implementations", "symbols"]).default("definition"),
      file: z.string().optional().describe("Defaults to the current buffer"),
      line: z.number().int().positive().optional().describe("1-based; defaults to the cursor line"),
      column: z.number().int().positive().optional(),
      limit: z.number().int().positive().optional().describe("Max items, default 50"),
    },
    (args) => run("editor.lsp", args),
  );

  server.tool(
    "editor_highlight",
    "Highlight a line range in a file without moving the cursor.",
    {
      file: z.string().optional().describe("Defaults to the current buffer's file"),
      start_line: z.number().int().positive(),
      end_line: z.number().int().positive(),
    },
    (args) => run("editor.highlight", args),
  );

  const PATH_METHOD = { list: "explore.path", back: "explore.back", forward: "explore.forward" };

  server.tool(
    "explore_path",
    "Shared exploration path: every file you opened is one hop. mode=list returns the hops; back/forward move the user along them.",
    {
      mode: z
        .enum(["list", "back", "forward"])
        .optional()
        .describe("Defaults to list"),
    },
    (args) => run(PATH_METHOD[args.mode ?? "list"], {}),
  );

  server.tool(
    "editor_tour",
    "Show a walkthrough when requested or clearly useful for reading an ordered multi-file flow: one loclist of blocks plus explanations pinned above the code. Send the whole ordered list in one call; do not narrate or confirm block by block.",
    {
      title: z.string().optional().describe("Short name of the flow, e.g. '下单校验链路'"),
      append: z
        .boolean()
        .optional()
        .describe("Append to the tour that is already shown instead of replacing it; use only when one call cannot carry the whole flow"),
      blocks: z
        .array(
          z.object({
            file: z.string().describe("Absolute path or path relative to the workspace root"),
            line: z.number().int().positive().optional().describe("1-based first line of the block"),
            end_line: z.number().int().positive().optional().describe("1-based last line of the block"),
            note: z.string().describe("Why this block matters, one or two sentences"),
          }),
        )
        .min(1)
        .describe("Ordered blocks; the user walks them with prev/next"),
    },
    (args) => run("tour.set", { title: args.title, blocks: args.blocks }),
  );

  await server.connect(new StdioServerTransport());
}
