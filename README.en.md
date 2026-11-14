# ave

Wires Neovim to a native coding agent (Claude Code / Codex / Pi) so the agent can drive the editor directly: jump to an implementation, highlight a range, and string file hops into one exploration path.

The editor stays on the left, the agent keeps its own TUI on the right (no reimplemented chat UI), and a local socket is the two-way channel in between.

```
nvim ── UDS(JSON-RPC/NDJSON) ── node bridge-helper ── MCP(stdio) ── claude / codex / pi
```

## Status

`0.1.0`: layout + terminal + bridge + `editor_context` / `editor_open` / `editor_highlight` / `explore_path` / `editor_lsp` / `editor_tour`, with a connection shim for all three agents.

- The exploration path stack works and is persisted per workspace (`stdpath("state")/ave/path-<hash>.json`), so it survives an nvim restart.
- Editor integration is on demand: ordinary file reads and edits do not open files, and explicit requests not to use ave or operate the editor take precedence.
- Guided tour: when a walkthrough is needed, the agent sends one ordered list of blocks (file + line range + explanation) in a single call; you step through them, and `3<leader>ag` jumps straight to block 3.
- All three agents operate the editor only through explicit tool calls; Pi needs `:Ave install pi` first.

## Install

Requires Neovim ≥ 0.10 and Node ≥ 20 (the agents themselves ship Node).

```lua
-- lazy.nvim
{
  "sunzhenkai/ave.nvim",
  dependencies = {},
  config = function() require("ave").setup() end,
}
```

Install the helper dependencies once:

```vim
:Ave install          " runs npm ci inside the plugin directory
:Ave install pi       " writes the user-level MCP config for Pi (~/.pi/agent/mcp.json)
```

Claude Code and Codex need no global setup: `ave` injects its MCP server per session via `--mcp-config` / `-c`. Pi only reads a user-level config, so run `:Ave install pi` once.

### LazyVim

LazyVim is a preset on top of lazy.nvim: anything dropped into `lua/plugins/` is imported automatically, so no key or `opts` bridge is needed.

```lua
-- ~/.config/nvim/lua/plugins/ave.lua
return {
  "sunzhenkai/ave.nvim",
  config = function() require("ave").setup() end,
}
```

One thing to watch: LazyVim's AI extras (`extras/ai/claudecode`, `sidekick`, `copilot-chat`) claim `<leader>a` as an AI group, and their `<leader>aa` / `<leader>as` collide with ave. Either skip those extras, or remap (list only what you change; the rest keep their defaults):

```lua
require("ave").setup({ keys = { toggle = "<leader>cA", send = "<leader>cS" } })
```

`<leader>` itself follows LazyVim (space by default); ave does not touch it.

## Usage

```vim
:Ave pick             " pick an agent in a floating window, then start it (<leader>aa does this)
:Ave open             " start the default agent (claude)
:Ave open codex       " start a specific agent
:Ave close
:Ave toggle           " close if open, otherwise start the default agent
:Ave stop             " stop the current agent process
:Ave status           " helper / socket / session state
:Ave back             " step back along the exploration path
:Ave forward          " step forward
:Ave path             " dump the path into a loclist
:Ave send             " paste the current line into the agent (:Ave send focus also jumps there)
:Ave ref              " paste an @file:Lx-Ly reference
:Ave ask              " ask ephemeral agent: type question, popup float (q to hide, auto-close on exit)
:Ave askhide          " hide ephemeral agent float (agent keeps running)
:Ave full             " fullscreen the panel / leave fullscreen
:Ave tour             " reopen the current tour's block list
:Ave tour off         " clear the tour
:Ave goto 3           " jump to tour block 3
```

Default keys (installed by `setup()`, no `:Ave` needed first; override them in `setup()`):

| Key | Action |
|---|---|
| `<leader>aa` | Open the agent picker, start the chosen agent, hand it the cursor |
| `<leader>a[` | Path back |
| `<leader>a]` | Path forward |
| `<leader>al` | Path loclist |
| `<leader>aF` | Fullscreen the panel (own tab, existing splits untouched) |
| `<leader>ag` | Next tour block; `3<leader>ag` jumps to block 3 (prompts for a number without a count) |
| `<leader>as` | Paste the selected lines into the agent prompt, focus stays in the editor (cursor line in normal mode) |
| `<leader>aS` | Same, then jump to the panel in terminal mode (no auto-submit) |
| `<leader>aR` | Send an `@file:Lx-Ly` reference and let the agent read the file itself |
| `<leader>aq` | Ask ephemeral agent: type a question, popup float (with selection in visual), closes on exit |
| `q` in float | Hide the float, agent keeps running (press `<leader>aq` to bring it back) |
| `Esc` (in panel) | Passed to the agent as-is (interrupt/cancel); the plugin never intercepts it |
| `Ctrl-n` / `F2` (in panel) | Single key back to normal mode (`Ctrl-[` is the same byte as `Esc`, so it cannot be used) |
| `Ctrl-\ Ctrl-N` (in panel) | Back to normal mode |
| `Ctrl-h/j/k/l` (in panel) | Move across windows without leaving terminal-mode first |
| `i` / `a` (panel normal mode) | Back to the agent input |

Tour and path are two different things: the path records explicit `editor_open` jumps, while the tour is a linear script the agent pushes once when needed. While a tour is active, `<leader>a[` / `<leader>a]` walk the tour; otherwise they walk the path.

Ask to “open the implementation of xxx in the editor” for a jump, or “create a walkthrough” / “walk me through the xxx flow with the code” for a tour. “Explain the xxx logic” normally produces text only; explicit requests not to use ave or operate the editor take precedence.

The agent side needs no manual setup: `ave` registers its MCP server the way each agent expects (see [docs/agents.md](docs/agents.md)).

`Esc` inside the panel is never taken by Neovim: the agent uses it to interrupt. Get back to normal mode with `Ctrl-n` or `F2` (one keystroke) and move windows with `Ctrl-h/j/k/l`. `Ctrl-[` looks like a separate key, but it is `Esc` down at the byte level (both are `0x1b`), so pressing it in the panel only interrupts the agent. If you really want the old double-`Esc` behaviour, set `esc_double = true` (the cost is that the first press has already reached the agent, so the interrupt still happens).

## Configuration

`agents.<name>.cmd` is the entire launch command; ave only appends what it needs (MCP config, system prompt), so the agent's own flags go straight in. The two common permission switches:

```lua
require("ave").setup({
  agents = {
    claude = { cmd = { "claude", "--permission-mode", "bypassPermissions" } },
    codex = { cmd = { "codex", "--dangerously-bypass-approvals-and-sandbox" } },
  },
})
```

Setting only one of them is fine; agents you leave out keep their default command. Both switches skip the agent's confirmations (codex also drops its sandbox), so enable them only in repositories you trust.

Other options: `agent` (which one starts by default), `width`, `focus_on_open`, `esc_double`, `node`, `helper`, `socket_dir`, `keys` — see `M.defaults` in `lua/ave/config.lua`. `agents` and `keys` merge entry by entry, so list only what you change.

## Tests

```bash
bash tests/run.sh
```

Two stages: `tests/e2e.lua` (pure Lua: path stack, jumps, protocol) and `bridge-helper/test/e2e.mjs` (over real MCP: `editor_context` → helper → UDS → nvim). The second stage launches a real nvim (`tests/host.lua`, needs a terminal with a UI: headless drags out the UDS reply until `vim.wait` times out) plus clangd for LSP; both are required.

## License

[MIT](LICENSE)

## Docs

- [docs/architecture.md](docs/architecture.md) — structure, protocol, where state lives
- [docs/agents.md](docs/agents.md) — how the three agents differ (measured, in Chinese)

## Design choices

- No chat UI of our own: the right-hand pane is the agent's terminal.
- No arbitrary Lua execution: the bridge only answers a whitelisted set of methods.
- Agent-supplied line numbers are treated as possibly stale: `snippet` is the preferred fallback anchor.
