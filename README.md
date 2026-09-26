# pitel

*pi + gptel*: the conversation is an editable Neovim markdown buffer; the Go
binary is just a provider client. No TUI, no hidden state.

## Philosophy (stolen from gptel)

Chat LLM APIs are stateless: every request sends the full message array. So
whoever holds the array holds the truth — and that can be a text buffer.

- **`# @system` / `# @user` / `# @assistant`** headings delimit messages.
- The buffer is the *only* state. Deleting a block removes it from the
  conversation — that's branching (`/tree` by deletion).
- Editing an assistant reply changes what the model "said". Writing your own
  `# @assistant` block steers it (prefill).
- Yanking is native Neovim yanking: no TUI cell padding, no trailing
  whitespace. Markdown rendering is your own `ft=markdown` setup
  (treesitter, render-markdown, ...), not the agent's problem.

## Layout

```
main.go              Go binary `pitel`: stdin JSON → streamed stdout. stdlib only.
lua/pitel/init.lua   Buffer parsing, streaming append, send/stop, winbar.
lua/pitel/fold.lua   Heading folds, view levels, message navigation (from fruit.nvim).
lua/pitel/session.lua Session persistence (markdown files) and picker.
plugin/pitel.lua     User commands.
```

## Build & install

```sh
CGO_ENABLED=0 go build -o ~/go/bin/pitel .   # pure Go, no gcc needed
```

Neovim: add this repo as a plugin (any plugin manager, or
`vim.opt.rtp:append("/opt/code/pitel")`), then:

```lua
require("pitel").setup({
  provider = "moonshot",
  model = "kimi-k3",
})
```

## Provider config

`~/.pitel/config.json` — any OpenAI-compatible endpoint:

```json
{
  "providers": {
    "moonshot": { "base_url": "https://api.moonshot.ai/v1", "api_key_env": "MOONSHOT_API_KEY" },
    "deepseek": { "base_url": "https://api.deepseek.com/v1", "api_key_env": "DEEPSEEK_API_KEY" },
    "openai":   { "base_url": "https://api.openai.com/v1",   "api_key_env": "OPENAI_API_KEY" }
  },
  "pricing": {
    "kimi-k3": { "input": 0.60, "output": 2.50 }
  }
}
```

API keys come from the named environment variables. Anthropic/Gemini-native
protocols are not implemented yet; use OpenRouter in the meantime.
`pricing` is optional (USD per 1M tokens) and enables the cost figure in
the session header.

## `~/.pitel`

Everything pitel owns lives in `~/.pitel` (pi-style):

- `config.json` — providers (above)
- `AGENTS.md` — system prompt for new chat buffers (configurable via
  `setup({ agents_file = ... })`); falls back to `config.system` when absent
- `sessions/<project-slug>/` — autosaved markdown session files

## Usage

- `:Pitel` — new chat buffer
- `<C-s>` (normal/insert) or `:PitelSend` — send the whole buffer
- `:PitelStop` — kill the in-flight request
- `:PitelUse moonshot kimi-k3` — switch provider/model for this buffer
- `:PitelSessions [all]` — resume a saved session (default: cwd project only)

The winbar shows `provider / model` and a busy spinner while a request is
in flight. Sessions are plain markdown, autosaved after every reply under
`~/.pitel/sessions/<project>/` — the buffer is renamed to the file,
so `:w` works too.

### Folding & navigation (ported from fruit.nvim)

`# @role` headings are folds; a closed fold shows role + first line.

- `<leader>1` outline · `<leader>2` user only · `<leader>3` conversation · `<leader>4` full
- `<Tab>` — toggle fold
- `]m`/`[m` — next/prev message · `]u`/`[u` user · `]a`/`[a` assistant

### Session header

Every buffer starts with a comment block (ignored by the parser) that tracks
the session:

```
<!-- pitel session · started 2026-09-26 14:33 · 1.5k in / 42 out · $0.0034
-->
```

The binary asks providers for token usage (`stream_options.include_usage`)
and reports it as a `pitel:usage` marker at the end of each reply; the Lua
side folds it into the running totals, refreshes the header and removes the
marker. The state lives in a JSON line inside the header, so it survives
saving and reopening sessions.

### Thinking blocks

Models that stream reasoning via the OpenAI-compatible `reasoning_content`
field (Moonshot/Kimi, DeepSeek) have their thinking wrapped in
`<!-- pitel:thinking -->` inside the assistant block. It renders in the
buffer (and folds away with the block) but `parse_buffer` excludes it from
the message array — thinking is never sent back to the provider.

## Deliberately not built (yet)

- **Tools / tool-call pairing.** Assistant `tool_calls` and their results have
  strict API pairing rules; sanitizing edited history around them is the real
  work. Deferred.
- **Branch persistence.** Delete something and it's gone. A JSONL snapshot
  store (id/parentId, pi-style) can come later if missed.
- **Multiple wire protocols.** OpenAI-compatible only.

## Protocol (Lua ↔ Go)

```
stdin:  {"messages":[{"role":"user","content":"..."}, ...]}
argv:   pitel send --provider NAME --model MODEL
stdout: raw assistant text, streamed as it arrives
stderr: error message, exit 1
```
