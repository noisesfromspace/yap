# yap

*Inspired by pi and gptel*: the conversation is a real Neovim buffer you
edit, so deleting text is branching and editing a reply is rewriting history.

Chat LLM APIs are stateless. Every request sends the full message array, so
whoever holds the array holds the truth. In yap that's a text buffer: `# @system` / `# @user` / `# @assistant` headings delimit messages, deleting a
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

## First run

1. From the repository root, build the backend and make sure `yap` is on
   Neovim's `PATH`:

   ```sh
   CGO_ENABLED=0 go build -o ~/.local/bin/yap ./agent
   ```

   Add `~/.local/bin` to `PATH` if needed. The plugin starts the backend when
   you open a chat; no separate server command is needed. With Nix,
   `nix develop` builds `.dev/bin/yap` and adds it to `PATH`.
2. Configure a provider in `~/.config/yap.json` (this example uses
   Moonshot's OpenAI-compatible API):

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

   Export the key before starting Neovim, e.g. `export MOONSHOT_API_KEY=…`.
   Keep the key out of the config file.
3. Install this repository as a Neovim plugin (or add it with
   `vim.opt.rtp:append("/path/to/yap")`), then configure it in your Neovim
   config:

   ```lua
   require("harness").setup({ provider = "moonshot", model = "kimi-k3" })
   ```
4. In Neovim, run `:Yap`, enter a prompt, and press `<C-s>`.

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

## Commands at a glance

`:Yap` opens an editable Markdown chat. Type under `# @user` and press `<C-s>`
(or run `:YapSend`) to send the whole transcript; the reply streams back into
the same buffer. Every send uses Neovim's current working directory as
request-only context.

Successful commands are quiet: edits show in the buffer, model changes show
in the winbar, and pickers show their selection. Warnings and errors still
notify. For command details and keymaps, see `:help yap-commands`.

| Command                            | Shortcut    | Purpose                                                               |
| ---------------------------------- | ----------- | --------------------------------------------------------------------- |
| `:Yap`                             |             | Start a chat.                                                         |
| `:YapSend`                         | `<C-s>`     | Send the transcript.                                                  |
| `:YapStop`                         | `<leader>c` | Stop the current request.                                             |
| `:YapChangeModel [provider/model]` | `<leader>m` | Pick or set this chat's model.                                        |
| `:YapLive`                         | `<leader>l` | Open the live tool/audit view.                                        |
| `:YapClear [keep]`                 |             | Replace older tool output with audit-log references; default keeps 2. |
| `:YapCompact`                      |             | Ask for a summary, then optionally remove superseded history.         |
| `:YapInsert [name]`                | `<C-t>`     | Insert a template or merge a skill into the system prompt.            |
| `:YapInsertHere [name]`            | `<leader>T` | Insert template/skill text at the cursor.                             |
| `:YapSessions [all]`               |             | Resume a saved session in this project, or all projects.              |
| `:YapInstances`                    | `<leader>r` | Pick any open chat; sessions needing attention come first.            |
| `:YapWaiting`                      | `<leader>w` | Pick a chat awaiting your reply.                                      |
| `:YapReload`                       |             | Reload Lua modules (development only).                                |

Templates and skills live in `~/.config/yap/templates/` and
`~/.config/yap/skills/`. `<leader>s` opens the scratch queue; send from it to
append queued text to the chat, or steer a running turn. The winbar shows the
active session/model, usage, fold view, and whether a turn is running or
awaiting your reply. `<leader>1` folds agent output, `<leader>2` folds tool
calls and thinking, and `<leader>3` unfolds everything. The `quickfix` tool can
populate Neovim's quickfix list, and `close_session` closes a chat after its
current turn while keeping it resumable from `:YapSessions`.

## Rendering

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
