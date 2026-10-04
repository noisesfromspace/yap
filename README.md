# yap

*Inspired by pi and gptel*: the conversation is a real Neovim buffer you
edit, so deleting text is branching and editing a reply is rewriting history.

Chat LLM APIs are stateless. Every request sends the full message array, so
whoever holds the array holds the truth. In yap that's a text buffer: `#
@system` / `# @user` / `# @assistant` headings delimit messages, deleting a
block is branching, editing a reply is rewriting history

It hooks into Neovim by:

- Text objects for messages and thinking/tool blocks (`dit` clears a
  block, `dam` drops a message)
- `]`/`[` navigation between messages (`]m`/`[m`), user prompts (`]u`/`[u`),
  assistant replies (`]a`/`[a`), tool/thinking blocks (`]t`/`[t`) etc
- A winbar showing the session description, model, token totals, cost, and
  streaming status (`▶N`)
- Folding views to collapse agent output or tool calls with keyboard shortcuts
  (<leader>1/2/3)
- Context slimming and compaction (:YapClear, :YapCompact)
- Templates and skills injected into the conversation (:YapInsert)
- Pickers via `vim.ui.select`, works with fzf-lua, telescope, mini.pick,
  snacks, or any picker plugin you use
- Plain-markdown sessions you can resume, fork, and render with any plugin
- Asynchronous streaming over `vim.system`, with a `User YapTurnDone` autocmd
  when a turn finishes

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
- `:YapLive` / `<leader>l` — watch tool output live in a persistent
  `yap://<session>-tail` buffer that renders the session's audit log as
  it streams. The audit log (`~/.yap/audit/<cwd-slug>/<session>.jsonl`)
  is JSON Lines, one event per line, and keeps full tool arguments and
  results
- `<leader>s` — toggle a scratch queue buffer: a fixed-height,
  file-backed jotter below the session (a quick queue of tasks for the
  agent; `:w` saves it next to the session as `<session>.queue` and an
  unsaved queue prompts on exit). Inside it, `<C-s>` sends the whole
  buffer (or the visual selection) to the chat and drains it. While the
  agent is streaming, `<C-s>` steers instead: the current line (or the
  selection) is injected at the next tool boundary as a `# @user` block,
  left in the jotter so you can keep editing it until it lands.
- `:YapClear [keep]` — slim the context: replace all but the last
  `keep` (default 2) tool result bodies with a pointer to the exact
  audit-log lines they were cleared from. write/edit tool headers are
  always slimmed (`[N lines]`); the diff below them shows the change
- `:YapCompact` — summarize the conversation: insert the compact prompt,
  send, then offer to delete the old history (the summary stays as an
  editable turn)
- `:YapInsert [name]` / `<leader>t` — insert a template (appended as
  `# @user`) or a skill (merged into `# @system`) from
  `~/.config/yap/templates/` and `~/.config/yap/skills/`; mid-turn a
  template steers the running agent instead (injected at the next tool
  boundary). `<leader>T` inserts verbatim at the cursor.
- `:YapSessions [all]` — resume a saved session
- `:YapInstances` / `<leader>r` — list every open session by file path
  with its status (`◉ waiting`, `✗ error`, `▶ running`, `○ idle`) and
  jump to the picked one (sessions are unlisted: they never appear in
  `:ls` or buffer pickers); `<leader>w` / `:YapWaiting` lists just the
  sessions awaiting your reply
- The agent's `quickfix` tool can fill the quickfix list with source
  locations, e.g. review findings. Each call pushes a new list, so previous
  ones stay reachable with `:colder` / `:cnewer`. Reopening a saved session
  doesn't re-run it.
- The agent's `close_session` tool closes the buffer once the turn has
  finished streaming and the session file has been saved — so "close the
  session when done" works as a tool call. The file is kept, so it stays
  resumable via `:YapSessions`.

The winbar leads with a `▶` busy beacon while the current session is
streaming, then a rollup of your other sessions: `▶N` streaming and `◉N`
awaiting your reply (the current buffer is never counted there).
After that: the session description, provider/model, and fold view (`Ⓕ1`-`Ⓕ3`).
Long descriptions are truncated, and token totals use compact `k`/`m` notation
on the right (with a context-fill gauge after the first turn),
followed by the trailing state glyph: busy / error / `◉
waiting` (the agent awaits your next prompt) / idle. A turn finishing in a
background chat fires `vim.notify` and a `User YapTurnDone` autocmd you can
hook. `<leader>1` folds all agent output except the last reply (user prompts
and the latest assistant stay open), `<leader>2` folds tool calls and thinking
(default when a session opens), `<leader>3` unfolds everything.

# Rendering
[touchup](https://git.boers.email/nodes/seed.boers.email/rad:z3idaVuBJSG4LUD3zbP2PoXfry3xX)
complements yap: a treesitter-based markdown rendering plugin that is yap-aware.
It colors the `yap:thinking` / `tool` / `error` / `usage` comment labels and
paints a whole tool region (header, result, diff) as one block. Any
renderer you already use (render-markdown, markview, or plain treesitter
highlighting) works fine on a yap buffer.

## Documentation

The full reference (buffer format, markers, sessions, folding, configuration,
and the design rules this project is built on) is in the vimdoc:

`vim :help yap`

Contributors: read `:help yap-rules` before changing behavior,
and update it when you do.
