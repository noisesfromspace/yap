# pitel

*Inspired by pi and gptel*: the conversation is an editable Neovim markdown
buffer; the Go binary is just a provider client. No TUI, no hidden state.

Chat LLM APIs are stateless — every request sends the full message array, so
whoever holds the array holds the truth. In pitel that's a text buffer:
`# @system` / `# @user` / `# @assistant` headings delimit messages, deleting
a block is branching, editing a reply is rewriting history, and yanking is
native Neovim yanking.

## Build & install

```sh
CGO_ENABLED=0 go build -o ~/go/bin/pitel ./agent   # pure Go, no cgo
```

Add this repo as a Neovim plugin (any plugin manager, or
`vim.opt.rtp:append("/opt/code/pitel")`), then:

```lua
require("harness").setup({ provider = "moonshot", model = "kimi-k3" })
```

Providers live in `~/.config/pitel.json` (any OpenAI-compatible endpoint):

```json
{ "providers": { "moonshot": { "base_url": "https://api.moonshot.ai/v1", "api_key_env": "MOONSHOT_API_KEY" } } }
```

## Quick start

- `:Pitel` — new chat buffer
- `<C-s>` — send the whole buffer
- `<leader>m` / `:PitelChangeModel` — switch models (queries the providers
  in config.json for their model lists)
- `:PitelStop` — kill the in-flight request
- `:PitelLive` / `<leader>l` — watch tool output live: one persistent
  `pitel://<session>-tail` buffer with a `$ command` header per call,
  written to a `<session>-tail` sidecar file next to the session from
  the start. The audit log at
  `~/.pitel/audit/<cwd-slug>/<session>.log` keeps the full record
  (full tool arguments and results)
- `:PitelClear [keep]` — slim the context: replace all but the last
  `keep` (default 2) tool result bodies with a pointer to the audit
  log. write/edit tool headers are always slimmed (`[N lines]`); the
  diff below them shows the change
- `:PitelInsert [name]` / `<leader>t` — insert a template (appended as
  `# @user`) or a skill (merged into `# @system`) from
  `~/.config/pitel/templates/` and `~/.config/pitel/skills/`;
  `<leader>T` inserts verbatim at the cursor. Compaction = insert a
  `compact.md` summarize-prompt template, send, then delete the old
  history.
- `:PitelSessions [all]` — resume a saved session

Provider/model, fold view (`Ⓕ1`-`Ⓕ3`), token totals and cost live in
the winbar. `<leader>1` folds all agent output (user prompts stay open;
default when a session opens), `<leader>2` folds tool calls and
thinking, `<leader>3` unfolds everything.

## Rendering

pitel buffers are plain markdown: thinking/tool/error blocks are HTML
comments, results are raw markdown, and the content is kept
CommonMark-sane (no stray `-->` inside comments, fences always
balanced). Any markdown renderer works — pitel itself only uses folds
and never conceal, so it stays out of your renderer's way.

[touchup](https://git.boers.email/nodes/seed.boers.email/rad:z3idaVuBJSG4LUD3zbP2PoXfry3xX)
complements pitel: a treesitter-based markdown rendering plugin that is
pitel-aware — it colors the `pitel:thinking` / `tool` / `error` /
`usage` comment labels and paints a whole tool region (header, result,
diff) as one block. But any renderer you already use — render-markdown,
markview, or just treesitter highlighting — works the same on a pitel
buffer as on any other markdown file.

## Testing

```sh
tests/run.sh   # go test ./... plus headless-Neovim suites against local mocks
```

## Documentation

Full reference — buffer format, markers, sessions, folding, configuration,
and the design rules this project is built on — is in the vimdoc:

```vim
:help pitel
```

Contributors (human or AI): read `:help pitel-rules` before changing
behavior, and update it when you do.
