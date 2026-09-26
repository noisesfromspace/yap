# pitel — research & design handoff

This file compactly captures the investigation and decisions that led to this
repo. Read it first. Current implementation state is at the bottom.

## Why pitel exists

The author used [pi coding agent](https://github.com/earendil-works/pi)
(npm: `@earendil-works/pi-coding-agent`, MIT, TypeScript/Node) and wants out:

1. **pi's fullscreen TUI conflicts with Neovim's embedded terminal.** Blocks
   are rendered as padded terminal cells, so yanking copies trailing
   whitespace and breaks commands. This is inherent to cell-based TUIs — no
   setting fixes it.
2. **pi moves too fast**, adding features the author doesn't need. Preference:
   minimal, self-owned, compiled (Go), recompile-on-change is fine.
3. Desired UX: **markdown rendering delegated to Neovim itself**
   (`ft=markdown`, treesitter, optionally render-markdown.nvim/markview.nvim).
   The agent emits raw markdown only — no ANSI, no padding, no TUI code.

## Core design (gptel's model, the key insight)

Chat LLM APIs are **stateless**: every request sends the full message array.
Whoever holds the array holds the truth — and that can be a text buffer.
Prior art: [gptel](https://github.com/karthink/gptel) (Emacs,
[manual](https://gptel.org/manual.html)) — the conversation is a plain
editable buffer; branching = editing text.

pitel = pi + gptel:

- `# @system` / `# @user` / `# @assistant` headings delimit messages.
- **The buffer is the only state.** Deleting a block = removing it from the
  conversation = branching ("`/tree` by deletion"). Neovim's built-in undo
  tree (`:undotree`) is a free branch navigator on top.
- Editing an assistant reply rewrites what the model "said"; writing your own
  `# @assistant` block steers it (prefill — Anthropic officially supports
  this pattern).
- Adjacent same-role blocks are merged on send (providers require role
  alternation — "Dragon 1", handled in `parse_buffer`).

## Deferred problems (deliberately NOT solved)

- **Dragon 2 — tool-call pairing.** OpenAI/Anthropic require assistant
  `tool_calls` turns to be followed by tool-result messages with matching
  IDs. Naive block deletion can orphan pairs and the API rejects the request.
  Future tool support must sanitize history around tool pairs (or render
  tool blocks atomically/read-only). Not built yet.
- **Dragon 3 — branch persistence.** Delete something and it's gone.
  Accepted. If missed later: pi's session model (append-only JSONL, entries
  with `id`/`parentId`, context = path root→leaf) is ~50 lines to replicate;
  see pi's `dist/core/session-manager.js`.

## Survey of alternatives (why none were adopted)

| Project | Lang | Verdict |
|---|---|---|
| [3code](https://github.com/capocasa/3code) | Nim | Nice scrollback-respecting CLI, broad providers, but no plugin API, no MCP, explicitly no subagents. Good UX reference only. |
| [PiG](https://github.com/MichaelKinsy/PiG) | Go | Ambitious Go port of pi claiming parity (tree, TS extensions). Only 3 commits — vaporware risk. Watch it, don't bet on it. |
| [crush](https://github.com/charmbracelet/crush) | Go | Mature, `crush run` stdout mode, MCP. But FSL-1.1-MIT license, no tree, no subagents. |
| [goose](https://github.com/aaif-goose/goose) | Rust | Mature, Apache-2.0, MCP, documented subagents. No conversation tree. Best "established" fallback. |
| [codex](https://github.com/openai/codex) | Rust | OpenAI-only providers. Disqualified. |
| [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim) / avante.nvim / gp.nvim | Lua | Proof the stream-to-markdown-buffer pattern works in Neovim; not minimal. |

Provider-abstraction libraries (for later, if hand-rolling stops scaling):
Go → [mozilla-ai/any-llm-go](https://github.com/mozilla-ai/any-llm-go);
Rust → [rig](https://github.com/0xPlaygrounds/rig). Currently unneeded:
`main.go` is stdlib-only.

## MCP: not needed

pi's extensions (the author's: Exa search, Playwright, GitHub, fetch,
monitoring, subagent — `~/.pi/agent/extensions/*.ts`) use only two pi APIs:
`pi.registerTool({name, schema, execute})` and lifecycle event hooks
(`session_start`, `tool_call`, `agent_start/settled`). Neither requires MCP.

- MCP exposes tools only — no equivalent of the hook bus, so it can't even
  replicate the pi extension model.
- MCP's value is reusing *other people's* tool servers. The author's tools
  are thin HTTP wrappers (Exa = one POST; GitHub = REST) — trivially
  reimplemented as native Go funcs, less code than an MCP client.
- If a third-party MCP server is ever wanted: `mark3labs/mcp-go`, additively,
  sharing the same tool registry.
- Future pitel tool model = in-process registry: name + JSON schema + Go
  func, plus a hook bus in the agent loop. (Dragon 2 applies when this lands.)

## Architecture

```
┌─ Neovim ─────────────────────┐     ┌─ pitel (Go, stdlib only) ────────┐
│ lua/pitel/init.lua           │     │ stdin: {"messages":[...]}        │
│  - buffer ↔ messages parser  │────▶│ argv: send --provider X --model Y│
│  - streaming append          │◀────│ stdout: raw text, streamed       │
│  - buffer is the ONLY state  │     │ stderr: errors, exit 1           │
└──────────────────────────────┘     │ config: ~/.config/pitel/config.json
                                     │  (OpenAI-compatible endpoints,   │
                                     │   API keys from env vars)        │
                                     └──────────────────────────────────┘
```

- No frontend/backend state split: the Lua side holds nothing between turns.
- Provider wire protocol: OpenAI-compatible `/chat/completions` SSE only
  (covers OpenAI, DeepSeek, Moonshot/Kimi, OpenRouter, z.ai, local servers).
  Anthropic/Gemini-native: later, or via OpenRouter.
- Build: `CGO_ENABLED=0 go build -o pitel .` (no gcc on the author's NixOS).

## Author's environment & preferences (context for decisions)

- NixOS, Neovim, Go 1.26. No gcc (use CGO_ENABLED=0).
- pi config: `~/.pi/agent/settings.json` (providers: moonshotai/kimi-k3
  default, deepseek, anthropic, gemini, openai enabled).
- Existing related work: `/opt/code/fruit.nvim` — a read-only pi-session
  viewer (JSONL → folded buffer, 4 filter views, live-follow via fs_event).
  Its view/filter/fold machinery (~1300 lines view.lua) is the reference for
  porting view levels onto pitel buffers later. Do NOT fork its read-only core.
- Rules: minimal code, no speculative features, comments stay, no emojis.

## Current implementation state (verified working)

- `main.go` (220 lines): `pitel send` — stdin JSON → streamed stdout.
  Config `~/.config/pitel/config.json`:
  `{"providers": {"NAME": {"base_url": "...", "api_key_env": "..."}}}`.
- `lua/pitel/init.lua` (213 lines): `parse_buffer` (headings → messages,
  role-merge, empty-block drop), `send` (vim.system + streaming append),
  `stop`, `new` (template buffer), `use` (per-buffer provider/model).
- `plugin/pitel.lua`: `:Pitel`, `:PitelSend`, `:PitelStop`, `:PitelUse`.
- Keymap: `<C-s>` send (normal+insert) in pitel buffers.
- Verified: multi-turn headless test against a mock SSE server — turn 2
  correctly sends `system,user,assistant,user`; replies stream into buffer.
- Bugs already fixed: nil-hole in template table; vim.SystemObj userdata
  can't be stored in `vim.b` (jobs live in module-local `running` table).

## Next steps (rough priority)

1. **Dogfood**: real `~/.config/pitel/config.json` with the author's
   providers; wire rtp into Neovim config; use daily.
2. Port fruit.nvim's fold/view-level machinery (outline/conversation/
   activity/full) onto pitel buffers.
3. Tool loop (Dragon 2): in-process Go tool registry + hook bus; port the
   pi extensions (Exa search, fetch, GitHub) as native tools.
4. Maybe: Anthropic-native protocol, branch persistence (Dragon 3),
   subagents (spawn `pitel` subprocesses à la pi's roles).
