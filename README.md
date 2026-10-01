# yap

*Inspired by pi and gptel*: the conversation is an editable Neovim markdown
buffer; the Go binary is just a provider client. No TUI, no hidden state.

Chat LLM APIs are stateless — every request sends the full message array, so
whoever holds the array holds the truth. In yap that's a text buffer:
`# @system` / `# @user` / `# @assistant` headings delimit messages, deleting
a block is branching, editing a reply is rewriting history, and yanking is
native Neovim yanking.

## Build & install

```sh
CGO_ENABLED=0 go build -o ~/go/bin/yap ./agent   # pure Go, no cgo
```

Add this repo as a Neovim plugin (any plugin manager, or
`vim.opt.rtp:append("/opt/code/yap")`), then:

```lua
require("harness").setup({ provider = "moonshot", model = "kimi-k3" })
```

Providers live in `~/.config/yap.json` (native OpenAI/Anthropic/Google/DeepSeek,
or any OpenAI-compatible endpoint):

```json
{ "providers": { "moonshot": { "base_url": "https://api.moonshot.ai/v1", "api_key_env": "MOONSHOT_API_KEY" } } }
```

## Development (Nix)

Run from the repo root:

```sh
nix develop
```

This builds the backend into `.dev/bin/yap` and puts it on PATH,
plus `go` and `neovim`. Three launchers start a clean dev Neovim
(`-u NONE -i NONE`) with only this plugin loaded from the working tree:

```sh
yap-nvim                 # clean: yap only
yap-nvim-treesitter      # + markdown treesitter syntax highlighting
yap-nvim-touchup         # + the touchup.nvim renderer
yap-nvim-render-markdown # + the render-markdown.nvim renderer
```

`yap-nvim-touchup` loads touchup from `$TOUCHUP_ROOT` (default
`/opt/code/touchup.nvim`; override to point at another checkout).
Re-enter the shell (or `go build -o .dev/bin/yap ./agent`) after
editing the agent.

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

The session description, provider/model, fold view (`Ⓕ1`-`Ⓕ3`), token totals
and cost live in the winbar. Long descriptions are truncated, and token totals
use compact `k`/`m` notation. Its trailing glyph marks busy / error /
`◉ waiting` (the agent
awaits your next prompt) / idle, and whose `◉N` rollup shows how many
OTHER sessions await your reply. A turn finishing in a background chat
fires `vim.notify` — and a `User YapTurnDone` autocmd you can hook. `<leader>1` folds all agent output (user prompts stay open),
`<leader>2` folds tool calls and thinking (default when a session
opens), `<leader>3` unfolds everything.

## Rendering

yap buffers are plain markdown: thinking/tool/error blocks are HTML
comments, results are raw markdown, and the content is kept
CommonMark-sane (no stray `-->` inside comments, fences always
balanced). Any markdown renderer works — yap itself only uses folds
and never conceal, so it stays out of your renderer's way.

[touchup](https://git.boers.email/nodes/seed.boers.email/rad:z3idaVuBJSG4LUD3zbP2PoXfry3xX)
complements yap: a treesitter-based markdown rendering plugin that is
yap-aware — it colors the `yap:thinking` / `tool` / `error` /
`usage` comment labels and paints a whole tool region (header, result,
diff) as one block. But any renderer you already use — render-markdown,
markview, or just treesitter highlighting — works the same on a yap
buffer as on any other markdown file.

## Testing

```sh
tests/run.sh   # go test ./... plus headless-Neovim suites against local mocks
```

## Documentation

Full reference — buffer format, markers, sessions, folding, configuration,
and the design rules this project is built on — is in the vimdoc:

```vim
:help yap
```

Contributors (human or AI): read `:help yap-rules` before changing
behavior, and update it when you do.
