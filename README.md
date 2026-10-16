# yap

An LLM agent that lives in a Neovim buffer. You chat with it, and it can
edit files, run commands, search the web, and delegate to subagents. The
conversation is a plain Markdown buffer you edit like any other text or
file. 

Chat APIs are stateless: every request sends the whole conversation again.
So the buffer is the conversation. Delete a message and the next request
won't include it. Edit a reply and the model continues from your version.
Branching, prefill, and undo navigation are just editing.

Inspired by pi and gptel.

## What you get

- Text objects for messages, thinking, and tool regions (`dit` clears a
  region, `dam` drops a message).
- `]`/`[` navigation between messages and regions (`]m`, `]u`, `]a`, `]t`).
- A winbar with session description, model, token totals, cost, and
  streaming status.
- Folding to collapse agent output or tool calls (`<leader>1/2/3`).
- Sessions as plain Markdown files you can resume, fork, and render.
- Subagents create new markdown files that are easy to track and manipulate.
- Templates and skills merged into the conversation (`:YapInsert`).
- Options are presented with whatever picker you use (`vim.ui.select`).
- Drop images into the chat and the will get interpreted by the model. 

## Tools

The agent ships with a fixed set of tools. It reads and edits files, runs
bash, python, and ssh, searches the web, reads GitHub, drives a browser
with Playwright, and delegates to subagents in separate sessions. Independent
read-only calls in one round run concurrently (up to four). For slow bash,
fetch, or websearch work, `start_task` returns a turn-scoped handle so the agent
can continue independent work and later call `wait_tasks` for the result.  
See `:help yap-tools`.

## First run

Yap needs Neovim 0.13 or newer (`vim.fs.mkdir`, `vim.npcall`). 

1. Build the backend and put `yap` on Neovim's `PATH`:

   ```sh
   CGO_ENABLED=0 go build -o ~/.local/bin/yap ./agent
   ```

2. Configure a provider in `~/.config/yap/settings.json`:

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

   Export the key before starting Neovim: `export MOONSHOT_API_KEY=…`.

3. Install this repo as a Neovim plugin, or append
   `vim.opt.rtp:append("/path/to/yap")` to your config, then:

   ```lua
   require("harness").setup({ provider = "moonshot", model = "kimi-k3" })
   ```

4. Run `:Yap`, type under `# @user`, and press `<C-s>`.

## Commands

`:Yap` opens an editable Markdown session. The reply streams back into the
same buffer. Every send uses Neovim's current working directory as request-only context. 

| Command                                   | Shortcut    | Purpose                                                            |
| ----------------------------------------- | ----------- | ------------------------------------------------------------------ |
| `:Yap`                                    |             | Start a session.                                                   |
| `:YapSend`                                | `<C-s>`     | Send the transcript.                                               |
| `:YapStop`                                | `<C-c>`     | Stop the current request.                                          |
| `:YapChangeModel [provider/model]`        | `<leader>m` | Pick or set this session's model.                                  |
| `:YapLive`                                | `<leader>l` | Open the live tool tail (streaming output).                        |
| `:YapGuard`                               | `<leader>g` | Open the guard board: parked approvals, advisories and history.    |
| `:YapClear [keep]`                        |             | Replace older tool output with audit-log references.               |
| `:YapCompact`                             |             | Summarize, then optionally drop superseded history.                |
| `:YapEval [instruction]`                  |             | Replace the visual selection with the model's output (one-shot, no tools). |
| `:YapInsert [name]`                       | `<C-t>`     | Insert a template or merge a skill.                                |
| `:YapSessions [scope]`                    |             | Resume a saved session (`cwd`, `all`).                             |
| `:YapFork [name]`                         |             | Copy the conversation to an independent buffer; edit it to branch. |
| Lua: `insert(name, { at_cursor = true })` | `<leader>T` | Insert template/skill text at the cursor.                          |
| Lua: `instances()`                        | `<leader>r` | Pick another open session.                                         |
| Lua: `waiting()`                          | `<leader>w` | Pick a session awaiting your reply (or stopped).                   |
| Lua: `history()`                          | `<leader>y` | Pick a saved session with live status.                             |
| Lua: `change_default_model()`             | `<leader>M` | Pick the default model for new sessions.                           |

## Rendering

Markdown renders should work, but output or user input could break it. 
[touchup](https://git.boers.email/martijn/touchup.nvim)
adds yap-aware rendering: it colors the `yap:thinking` / `tool` / `error` /
`usage` labels and draws each tool region as one region.

## Terminology

| Term                | Meaning                                                               |
| ------------------- | --------------------------------------------------------------------- |
| session             | one conversation: Markdown file + audit log + scratch queue           |
| session buffer      | the Neovim buffer editing a session                                   |
| message             | a `# @role` heading plus its body                                     |
| region              | a marker-delimited span: tool, thinking, error, or ui                 |
| tool region         | one tool call + its result                                            |
| turn                | one completed send → one assistant reply                              |
| send                | the action and in-flight request (`:YapSend` / `<C-s>`)               |
| prefill             | hand-writing an `# @assistant` message to continue from it            |
| steer               | mid-turn injection of a `# @steer` body at a model boundary           |
| advisory / approval | the alert gate's run-with-warning / pause-for-approval outcomes       |
| agent definition    | a `~/.config/yap/agents/<name>.md` file describing a subagent (not a “role”) |
| audit log / view    | the append-only `.jsonl` record, and the `:YapLive` tool-tail buffer |

The full vocabulary is in `:help yap-glossary`.

## Notes

- yap uses a Nerd Font by default for winbar and picker glyphs. Set
  `nerd_font = false` in setup for plain Unicode.
- This is experimental. Editing inside a streaming reply can mix your text
  with the model's output, and streaming edits can interfere with undo.

## Documentation

The full reference is in `:help yap` (`doc/yap.txt`). The contributor-facing
contract — the Lua \<-> Go wire protocol and the numbered business rules —
lives in [`CONTRIBUTING.md`](CONTRIBUTING.md), together with how to run the
test suite (`tests/run.sh`, or `nix develop --command tests/run.sh` for the
whole environment). AI assistants (and any human
contributor) editing this repository MUST read `CONTRIBUTING.md` before
changing behaviour, and update it when they do.
