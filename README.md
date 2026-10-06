# yap

An LLM agent that lives in a Neovim buffer. You chat with it, and it can
edit files, run commands, search the web, and delegate to subagents. The
conversation is a plain Markdown buffer you edit like any other text or
file.

Chat APIs are stateless: every request sends the whole conversation again.
So the buffer is the conversation. Delete a message and the next request
won't include it. Edit a reply and the model continues from your version.
Branching, prefill, and undo navigation are just editing.

A session is a Markdown file in `~/.yap/sessions/<project>/`

Inspired by pi and gptel.

## What you get

- Text objects for messages, thinking, and tool blocks (`dit` clears a
  block, `dam` drops a message).
- `]`/`[` navigation between messages and blocks (`]m`, `]u`, `]a`, `]t`).
- A winbar with session description, model, token totals, cost, and
  streaming status.
- Folding to collapse agent output or tool calls (`<leader>1/2/3`).
- Sessions as plain Markdown files you can resume, fork, and render.
- Templates and skills merged into the conversation (`:YapInsert`).
- Whatever picker you use (`vim.ui.select`).
- Async streaming over `vim.system`, with a `User YapTurnDone` autocmd.

## Tools

The agent ships with a fixed set of tools. It reads and edits files, runs
bash, python, and ssh, searches the web, reads GitHub, drives a browser
with Playwright, and delegates to subagents in separate sessions. Tools run
on your machine with no sandbox; some destructive commands require approval
first. See `:help yap-tools`.

## First run

1. Build the backend and put `yap` on Neovim's `PATH`:

   ```sh
   CGO_ENABLED=0 go build -o ~/.local/bin/yap ./agent
   ```

   The plugin starts the backend when you open a chat; there is no server
   to run. With Nix, `nix develop` builds `.dev/bin/yap` and puts it on
   `PATH`.

2. Configure a provider in `~/.config/yap.json`:

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
   Keep the key out of the config file.

3. Install this repo as a Neovim plugin, or append
   `vim.opt.rtp:append("/path/to/yap")` to your config, then:

   ```lua
   require("harness").setup({ provider = "moonshot", model = "kimi-k3" })
   ```

4. Run `:Yap`, type under `# @user`, and press `<C-s>`.

## Commands

`:Yap` opens an editable Markdown chat. The reply streams back into the
same buffer. Every send uses Neovim's current working directory as
request-only context. Commands are quiet on success; warnings and errors
still notify.

| Command                            | Shortcut    | Purpose                                              |
| ---------------------------------- | ----------- | ---------------------------------------------------- |
| `:Yap`                             |             | Start a chat.                                        |
| `:YapSend`                         | `<C-s>`     | Send the transcript.                                 |
| `:YapStop`                         | `<C-c>`     | Stop the current request.                            |
| `:YapChangeModel [provider/model]` | `<leader>m` | Pick or set this chat's model.                       |
| `:YapLive`                         | `<leader>l` | Open the live tool/audit view.                       |
| `:YapClear [keep]`                 |             | Replace older tool output with audit-log references. |
| `:YapCompact`                      |             | Summarize, then optionally drop superseded history.  |
| `:YapInsert [name]`                | `<C-t>`     | Insert a template or merge a skill.                  |
| `:YapInsertHere [name]`            | `<leader>T` | Insert template/skill text at the cursor.            |
| `:YapSessions [all]`               |             | Resume a saved session.                              |
| `:YapFork [name]`                  |             | Fork the conversation into a new session.            |
| `:YapInstances`                    | `<leader>r` | Pick another open chat.                              |
| `:YapWaiting`                      | `<leader>w` | Pick a chat awaiting your reply (or stopped).        |
| `:YapReload`                       |             | Reload Lua modules (development only).               |

Templates and skills live in `~/.config/yap/templates/` and
`~/.config/yap/skills/`. The scratch buffer (`<leader>s`) holds notes,
steering text for the running turn, and queued prompts. See
`:help yap-keymaps` for the full list.

## Rendering

Any Markdown renderer you use works on a yap buffer.
[touchup](https://git.boers.email/nodes/seed.boers.email/rad:z3idaVuBJSG4LUD3zbP2PoXfry3xX)
adds yap-aware rendering: it colors the `yap:thinking` / `tool` / `error` /
`usage` labels and draws each tool region as one block.

## Notes

- yap uses a Nerd Font by default for winbar and picker glyphs. Set
  `nerd_font = false` in setup for plain Unicode.
- This is experimental. Editing inside a streaming reply can mix your text
  with the model's output, and streaming edits can interfere with undo.

## Documentation

The full reference is in `:help yap`. Contributors should read
`:help yap-rules` before changing behavior, and update it when they do.
