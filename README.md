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
CGO_ENABLED=0 go build -o ~/go/bin/pitel .   # pure Go, no cgo
```

Add this repo as a Neovim plugin (any plugin manager, or
`vim.opt.rtp:append("/opt/code/pitel")`), then:

```lua
require("pitel").setup({ provider = "moonshot", model = "kimi-k3" })
```

Providers live in `~/.pitel/config.json` (any OpenAI-compatible endpoint):

```json
{ "providers": { "moonshot": { "base_url": "https://api.moonshot.ai/v1", "api_key_env": "MOONSHOT_API_KEY" } } }
```

## Quick start

- `:Pitel` — new chat buffer
- `<C-s>` — send the whole buffer
- `<leader>m` / `:PitelChangeModel` — switch models (queries the providers
  in config.json for their model lists)
- `:PitelStop` — kill the in-flight request
- `:PitelSessions [all]` — resume a saved session

Provider/model, token totals and cost live in the winbar.

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
