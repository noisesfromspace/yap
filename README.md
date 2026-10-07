# yap

An LLM agent that lives in a Neovim buffer. You chat with it, and it can
edit files, run commands, search the web, and delegate to subagents. The
conversation is a plain Markdown buffer you edit like any other text or
file.

Chat APIs are stateless: every request sends the whole conversation again.
So the buffer is the conversation. Delete a message and the next request
won't include it. Edit a reply and the model continues from your version.
Branching, prefill, and undo navigation are just editing.

A session lives in its own `~/.yap/sessions/<project>/<name>/` directory: the
conversation Markdown (`session.md`), its append-only audit log
(`audit.jsonl`), and an optional scratch notes file (`notes.md`). Photo
attachments remain in a shared content-addressed asset store, referenced by
the Markdown frontmatter. The Markdown is the conversation; the sidecars
carry tool output, usage, notes, and image bytes.

Inspired by pi and gptel.

## What you get

- Text objects for messages, thinking, and tool regions (`dit` clears a
  region, `dam` drops a message).
- `]`/`[` navigation between messages and regions (`]m`, `]u`, `]a`, `]t`).
- A winbar with session description, model, token totals, cost, and
  streaming status.
- Folding to collapse agent output or tool calls (`<leader>1/2/3`).
- Sessions as plain Markdown files you can resume, fork, and render.
- Templates and skills merged into the conversation (`:YapInsert`).
- Whatever picker you use (`vim.ui.select`).

## Tools

The agent ships with a fixed set of tools. It reads and edits files, runs
bash, python, and ssh, searches the web, reads GitHub, drives a browser
with Playwright, and delegates to subagents in separate sessions. Independent
read-only calls in one round run concurrently (up to four). For slow bash,
fetch, or websearch work, `start_task` returns a turn-scoped handle so the agent
can continue independent work and later call `wait_tasks` for the result. Yap
waits for outstanding tasks before a final answer. Tools run
on your machine with no sandbox; some destructive commands require approval
first. See `:help yap-tools`.

## First run

1. Build the backend and put `yap` on Neovim's `PATH`:

   ```sh
   CGO_ENABLED=0 go build -o ~/.local/bin/yap ./agent
   ```

   The plugin starts the backend when you open a session; there is no server
   to run. With Nix, `nix develop` builds the agent into
   `$XDG_CACHE_HOME/yap/bin/yap` (default `~/.cache/yap/bin/yap`) and puts it
   on `PATH`.
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

`:Yap` opens an editable Markdown session. The reply streams back into the
same buffer. Every send uses Neovim's current working directory as
request-only context. Commands are quiet on success; warnings and errors
still notify.

| Command                                   | Shortcut    | Purpose                                                            |
| ----------------------------------------- | ----------- | ------------------------------------------------------------------ |
| `:Yap`                                    |             | Start a session.                                                   |
| `:YapSend`                                | `<C-s>`     | Send the transcript.                                               |
| `:YapAttach`                              |             | Import the photo path on the current user line as an attachment.   |
| `:YapStop`                                | `<C-c>`     | Stop the current request.                                          |
| `:YapChangeModel [provider/model]`        | `<leader>m` | Pick or set this session's model.                                  |
| `:YapLive`                                | `<leader>l` | Open the live tool/audit view.                                     |
| `:YapAlerts`                              |             | Review advisories and approval requests in their sessions.         |
| `:YapApproval`                            |             | Answer Run/Deny after inspecting a paused request.                 |
| `:YapClear [keep]`                        |             | Replace older tool output with audit-log references.               |
| `:YapCompact`                             |             | Summarize, then optionally drop superseded history.                |
| `:YapInsert [name]`                       | `<C-t>`     | Insert a template or merge a skill.                                |
| `:YapSessions [scope]`                    |             | Resume a saved session (`cwd`, `all`).                             |
| `:YapFork [name]`                         |             | Copy the conversation to an independent buffer; edit it to branch. |
| Lua: `insert(name, { at_cursor = true })` | `<leader>T` | Insert template/skill text at the cursor.                          |
| Lua: `instances()`                        | `<leader>r` | Pick another open session.                                         |
| Lua: `waiting()`                          | `<leader>w` | Pick a session awaiting your reply (or stopped).                   |
| Lua: `history()`                          | `<leader>y` | Pick a saved session with live status.                             |
| Lua: `change_default_model()`             | `<leader>M` | Pick the default model for new sessions.                           |

Templates and skills live in `~/.config/yap/templates/` and
`~/.config/yap/skills/`. The scratch buffer (`<leader>s`) holds notes,
steering text for the running turn, and queued prompts. Steering delivered
at a model boundary is removed from scratch; steering that misses the last
boundary or is stopped remains a draft, with a warning, for an explicit
`<C-s>`. A queued prompt is only removed after its send starts successfully.
See
`:help yap-keymaps` for the full list.

## Photo attachments

In a Yap user message, drop a PNG or JPEG from your file manager onto Ghostty
while Neovim is in Insert mode, on a line by itself. Write your question and
send normally: Yap automatically imports the path and replaces it with a
visible `![FILE: name](file:///...)` reference before sending the photo as an
image part. No `:YapAttach` step is needed. You can still use `:YapAttach`
to import a path manually before sending. Yap copies up to 10 MiB into a
private asset store under Neovim's data directory. Any standalone absolute
PNG/JPEG path in a user message (including one you typed) is imported on send;
paths inside prose and ordinary Markdown images remain text. Removing the
reference from the session stops sending it. Retain the asset store when moving
or restoring sessions; the Markdown file alone does not contain the image.
Supported image formats and size limits also depend on your model/provider.

## Rendering

Markdown renders should work, but output or user input could break it. 
[touchup](https://git.boers.email/nodes/seed.boers.email/rad:z3idaVuBJSG4LUD3zbP2PoXfry3xX)
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
| agent definition    | a `~/.yap/agents/<name>.md` file describing a subagent (not a “role”) |
| audit log / view    | the append-only `.jsonl` record, and the rendered `:YapLive` buffer   |

The full vocabulary is in `:help yap-glossary`.

## Notes

- yap uses a Nerd Font by default for winbar and picker glyphs. Set
  `nerd_font = false` in setup for plain Unicode.
- This is experimental. Editing inside a streaming reply can mix your text
  with the model's output, and streaming edits can interfere with undo.

## Documentation

The full reference is in `:help yap` (`doc/yap.txt`). The contributor-facing
contract — the Lua \<-> Go wire protocol and the numbered business rules —
lives in [`CONTRIBUTING.md`](CONTRIBUTING.md). AI assistants (and any human
contributor) editing this repository MUST read `CONTRIBUTING.md` before
changing behavior, and update it when they do.
