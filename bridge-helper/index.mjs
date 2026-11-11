#!/usr/bin/env node
// ave bridge helper: MCP stdio server + Neovim UDS client.
// 子命令 `ping` / `call <method> [json]` 用于无 agent 时手工排查链路。
import net from "node:net";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const socketPath = process.env.WORKBENCH_SOCKET;
const DEFAULT_TIMEOUT_MS = 5000;

let seq = 0;
let conn = null;
let buf = "";
const pending = new Map();

function connect() {
  if (conn) return Promise.resolve(conn);
  if (!socketPath) return Promise.reject(new Error("WORKBENCH_SOCKET is not set"));
  return new Promise((resolve, reject) => {
    const c = net.createConnection(socketPath);
    c.setEncoding("utf8");
    c.once("connect", () => {
      conn = c;
      resolve(c);
    });
    c.once("error", reject);
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

const [sub, a, b] = process.argv.slice(2);

if (sub === "call" || sub === "ping") {
  const method = sub === "ping" ? "ping" : a;
  const params = sub === "ping" ? {} : b ? JSON.parse(b) : {};
  try {
    process.stdout.write(JSON.stringify(await call(method, params)) + "\n");
  } catch (e) {
    process.stderr.write(String(e.message ?? e) + "\n");
    process.exitCode = 1;
  }
} else {
  const server = new McpServer(
    { name: "ave", version: "0.1.0" },
    {
      instructions: [
        "This server is attached to the user's Neovim session.",
        "Call editor_context before answering questions about 'this file', 'the current selection', or 'where the user is'.",
        "When you locate an implementation the user asked about, call editor_open so the editor follows you instead of pasting code.",
        "Pass snippet (one stable unique line of code) together with line; it survives edits and tells you when a line number went stale.",
        "For multi-file walkthroughs, call editor_open for each hop so the user can follow the path in the editor.",
      ].join(" "),
    },
  );

  server.tool(
    "editor_context",
    "Current Neovim state: file, cursor, visual selection, filetype, workspace root.",
    {},
    () => run("editor.context", {}),
  );

  server.tool(
    "editor_open",
    "Open a file in the user's editor window and put the cursor on a line. Set focus=false (default) to keep the user's cursor where it is.",
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
    "editor_highlight",
    "Highlight a line range in a file without moving the cursor.",
    {
      file: z.string().optional().describe("Defaults to the current buffer's file"),
      start_line: z.number().int().positive(),
      end_line: z.number().int().positive(),
    },
    (args) => run("editor.highlight", args),
  );

  await server.connect(new StdioServerTransport());
}
