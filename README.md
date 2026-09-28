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
require("pitel").setup({ provider = "moonshot", model = "kimi-k3" })
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
- `:PitelLive` / `<leader>l` — watch a running tool's output (opens a
  terminal tailing the tool's log; opens automatically by default)
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
