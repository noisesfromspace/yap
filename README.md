# yap

*Inspired by pi and gptel*: the conversation is an editable Neovim markdown
buffer; the Go binary is just a provider client. No TUI, no hidden state.

Chat LLM APIs are stateless — every request sends the full message array, so
whoever holds the array holds the truth. In yap that's a text buffer: `#
@system` / `# @user` / `# @assistant` headings delimit messages, deleting a
block is branching, editing a reply is rewriting history

It hooks into Neovim by:

- Rich text-object support for messages and thinking/tool blocks, with actions
  like `dit` to clear a block and `dam` to drop a message
- `]`/`[` navigation between messages (`]m`/`[m`), user prompts (`]u`/`[u`),
  assistant replies (`]a`/`[a`), tool/thinking blocks (`]t`/`[t`) etc
- A winbar overview of sessions, showing streaming status (`▶N`)
- Folding views to collapse agent output or tool calls with keyboard shortcuts
  (<leader>1/2/3)
- Context slimming and compaction (:YapClear, :YapCompact)
- Templates and skills injected into the conversation (:YapInsert)
- Pickers that use `vim.ui.select`, works on fzf-lua, telescope, mini.pick,
  snacks, or any other picker plugin
- A winbar with session description, model, token totals and cost
- Plain-markdown sessions you can resume, fork, and render with any plugin
- Asynchronous streaming over `vim.system` and a `User YapTurnDone` autocmd
  for hooking turn completion

This isn't the most stable approach. Removing things or incoming text could put
the session in unexpected states. Making edits while the buffer is running will
overwrite the undohistory. This flexability gives it power.

## Build & install

```sh
CGO_ENABLED=0 go build -o ~/go/bin/yap ./agent
```

Add this repo as a Neovim plugin (any plugin manager, or `vim.opt.rtp:append("/opt/code/yap")`)

**Setup**
```lua
require("harness").setup({ provider = "moonshot", model = "kimi-k3" })
```

Every keymap in the Quick start list below is a `keymaps` config key; set
one to `""` to disable it, e.g. `keymaps = { stop = "<M-Esc>" }`.

Providers live in `~/.config/yap.json` (native OpenAI/Anthropic/Google/DeepSeek,
or any OpenAI-compatible endpoint):

```json
{
  "providers": {
    "moonshot": {
      "base_url": "https://api.moonshot.ai/v1",
      "api_key_env": "MOONSHOT_API_KEY"
    }
  }
}
```

## Development (Nix)

Run from the repo root:

```sh
nix develop
```

This builds the backend into `.dev/bin/yap` and puts it on PATH, plus `go` and
`neovim`. Three launchers start a clean dev Neovim (`-u NONE -i NONE`) with
only this plugin loaded from the working tree:

```sh
yap-nvim                 # clean: yap only
yap-nvim-treesitter      # + markdown treesitter syntax highlighting
yap-nvim-touchup         # + the touchup.nvim renderer
yap-nvim-render-markdown # + the render-markdown.nvim renderer
```

`yap-nvim-touchup` loads touchup from `$TOUCHUP_ROOT` (default
`/opt/code/touchup.nvim`; override to point at another checkout). Re-enter the
shell (or `go build -o .dev/bin/yap ./agent`) after editing the agent.

## Quick start

- `:Yap` — new chat buffer
- `<C-s>` — send the whole buffer. Every send also injects Neovim's current
  working directory into the request, so `:cd` takes effect on the next send
  and references such as “here” refer to the current Neovim directory. This
  request-only context is not written into the chat buffer.
- `<leader>m` / `:YapChangeModel` — switch models (queries the providers
  in config.json for their model lists)
- `:YapStop` / `<leader>c` — kill the in-flight request
- `:YapLive` / `<leader>l` — watch tool output live: one persistent
  `yap://<session>-tail` buffer that renders the session's audit log as
  it streams. The audit log at
  `~/.yap/audit/<cwd-slug>/<session>.jsonl` is JSON Lines — one
  structured event per line — and keeps the full record (full tool
  arguments and results)
- `<leader>s` — toggle a scratch queue buffer: a fixed-height, nofile
  jotter above the session (never written to disk; a quick queue of
  tasks for the agent)
- `:YapClear [keep]` — slim the context: replace all but the last
  `keep` (default 2) tool result bodies with a pointer to the exact
  audit-log lines they were cleared from. write/edit tool headers are
  always slimmed (`[N lines]`); the diff below them shows the change
- `:YapCompact` — summarize the conversation into a compact context:
  insert the compact prompt, send, then offer to delete the superseded
  history (the summary stays a visible, editable turn)
- `:YapInsert [name]` / `<leader>t` — insert a template (appended as
  `# @user`) or a skill (merged into `# @system`) from
  `~/.config/yap/templates/` and `~/.config/yap/skills/`;
  `<leader>T` inserts verbatim at the cursor. Compaction = insert a
  `compact.md` summarize-prompt template, send, then delete the old
  history — or just run `:YapCompact`.
- `:YapSessions [all]` — resume a saved session
- `:YapInstances` / `<leader>r` — list every open session by file path
  with its status (`◉ waiting`, `✗ error`, `▶ running`, `○ idle`) and
  jump to the picked one (sessions are unlisted: they never appear in
  `:ls` or buffer pickers)
- The agent's `quickfix` tool can replace the current quickfix list with
  multiple source locations, e.g. review findings. Each call creates a new
  quickfix history entry, so previous lists remain available with `:colder`
  / `:cnewer`. The side effect happens only for a live tool call; reopening a
  saved session does not replay it.

The winbar leads with a `▶` busy beacon while the current session is
streaming, then a raised island rolling up ALL OTHER sessions: `▶N` streaming
and `◉N` awaiting your reply (the current buffer is never counted there).
After that: the session description, provider/model, and fold view (`Ⓕ1`-`Ⓕ3`).
Long descriptions are truncated, and token totals use compact `k`/`m` notation
on the right, followed by the trailing state glyph — busy / error / `◉
waiting` (the agent awaits your next prompt) / idle. A turn finishing in a
background chat fires `vim.notify` — and a `User YapTurnDone` autocmd you can
hook. `<leader>1` folds all agent output (user prompts stay open), `<leader>2`
folds tool calls and thinking (default when a session opens), `<leader>3`
unfolds everything.

# Rendering
[touchup](https://git.boers.email/nodes/seed.boers.email/rad:z3idaVuBJSG4LUD3zbP2PoXfry3xX)
complements yap: a treesitter-based markdown rendering plugin that is yap-aware
— it colors the `yap:thinking` / `tool` / `error` / `usage` comment labels and
paints a whole tool region (header, result, diff) as one block. But any
renderer you already use — render-markdown, markview, or just treesitter
highlighting — works the same on a yap buffer as on any other markdown file.

## Documentation

Full reference — buffer format, markers, sessions, folding, configuration, and
the design rules this project is built on — is in the vimdoc:

`vim :help yap `

Contributors (human or AI): read `:help yap-rules` before changing behavior,
and update it when you do.
