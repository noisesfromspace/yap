# Contributing to Yap

## Contributor policy

No large refactors. Changes are kept narrowly scoped and local, so each one
is reviewable against the numbered rules below without sprawling across
modules. When a change would touch many areas, restructure code, or rework
behavior beyond the task at hand, do not edit this checkout in place: fork
the project first (copy it to a separate directory) and make the change
there, with permission of user. This applies to **AI agents**.

## Working with the rules

The rules are the design contract, identified by stable `R-...` slugs (not
ordinal numbers), so they can move between sections and new ones can be added
without renumbering anything. Code, tests, and discussions refer to them by
slug. For a behavior change, find the relevant rule, update it with the
implementation, and add or adjust the corresponding tests. Preserve the reason
for the rule, not just the current mechanics. For verification, run
`CGO_ENABLED=0 go test ./...` for Go changes or `tests/run.sh` for the full
Go + Neovim suite.

## Business rules

The invariants below are the design contract of this plugin. Each rule exists
for a reason; change the code and the rule together. AI assistants editing
this repository MUST keep this section up-to-date.

### Conversation document and persistence

#### R-buffer-only-state — The buffer is the only conversation state

Neither the Lua side nor the Go binary may keep message state between turns. An
explicit `![FILE: name](file:///...)` reference in a user message is an image
attachment; a standalone dropped or typed PNG/JPEG path is imported into a
local asset store and replaced with that reference on send. On send, standalone
absolute PNG/JPEG paths in user messages are imported automatically before
parsing; this also applies to typed paths and changes only matching user lines.
Go reads references on each send, extracts filename, detected media type, byte
size, and pixel dimensions when decodable, then sends that metadata as adjacent
text alongside the image bytes. Removing the reference removes the attachment;
missing/invalid assets fail the send. Each imported asset's basename is staged
and, on the next save, merged into the frontmatter `assets` list, so a session
declares which content-addressed files it references. The asset store must
accompany a session when moved to another machine. Why: branching by deletion,
prefill by editing, and undo-tree navigation only work if the buffer is the
single source of truth.

#### R-markers-not-sent — `<!-- yap:* -->` marker regions are never sent as buffer text

The parser skips them (thinking, error, usage, yap:ui) or flattens them
(yap:tool becomes plain assistant transcript text naming the tool, its JSON
arguments and result — the raw region text is still never sent). Why: thinking
or display payloads re-sent to the API pollute or break the conversation.
(Bug of record: the first error comment WAS sent back as assistant content.)

#### R-pre-heading-ignored — Lines before the first heading are ignored

The session header lives there. The parser's flush must clear the accumulator
when no role is set. (Bug of record: pre-heading text was prepended to the
first message until this was fixed.)

#### R-role-alternation — Adjacent same-role messages are merged on send; empty messages dropped

Why: providers require role alternation.

#### R-request-context-tail — Transient per-send context is appended to the trailing user message

The cwd and git snapshot (and any plugin-registered provider, see
`harness.context`) are request-only: evaluated at send time and never stored in
the buffer. They are appended to the most recent user message — normally the
trailing prompt, but a hand-written `# @assistant` prefill stays last so its
prefill semantics survive — never the system prefix. Why: a changing git
status in the system prefix would invalidate the provider's prompt cache for
the entire stable history and system prompt.

#### R-blank-lines — Exactly one blank line between messages, enforced locally at every write

Structural appends (headings, error markers) go through `append_lines()`,
which trims trailing blanks and prepends exactly one blank line itself — never
append a heading with `append_text()`. Before the append-only send starts,
standalone image paths in user messages are replaced locally by durable
references; other existing lines are not rewritten. The binary separates streamed tool
regions with blank lines. There is no buffer-wide normalize pass: apart from
those image-path replacements, sends do not rewrite existing lines, so what
gets sent is visible in the buffer before the request starts. Binary-emitted regions (thinking, tool regions, error markers)
carry no leading newlines and self-terminate with exactly one blank line; a
`pad()` in the agent loop bridges the two stateful transitions (heading → first
message, streamed text → first tool header).

(Bug of record: regions prepended `\n\n` while regions also ended in `\n`,
giving two blank lines between tool calls.)

Why: readable diffs, stable folds, gptel-like staticness. (Bug of record:
hand-rolled `"\n"` prefixes broke separation when trailing-blank trimming was
added; a buffer-wide normalize pass made every send rewrite the whole buffer
and churn fold state.)

#### R-session-is-file — Sessions are a small file set; file operations are the session operations

The file is created at buffer creation so a fresh session is file-backed
before the first reply. Saves follow every turn exit,
including errors and `:YapStop`, and go through `:write!` (not `writefile()`):
the buffer owns the file, so mtime bookkeeping, `:w`, and E13 all behave
normally. Every stream exit, including backend errors and `:YapStop`, repairs
any dangling streamed marker, appends a fresh `# @user` message, and saves that
final writable state. The markdown file is the only serialization of the
message history, but a session is a small set of sibling files: the audit log
(R-audit-log), the scratch notes file, and the frontmatter `assets` manifest
(R-frontmatter). `save()` follows buffer renames: a `:file` rename moves the
sidecars lazily (audit at the next turn, notes at the next scratch toggle),
while a `:saveas` copy rehomes them eagerly so the original session keeps its
own files and the copy continues with full history. Why: no second
serialization format to keep in sync. Session buffers (and their audit view
buffers) are unlisted — never in `:ls` or buffer pickers — so navigation uses
`<leader>r`, and a session's audit view opens with `:YapLive`.

#### R-frontmatter — The model state is durable YAML frontmatter; everything else is ephemeral

The frontmatter holds `provider`/`model` (the combo to resume with), `created_cwd` (the
exact working directory the session was created in — the session dir slug is
lossy), `models` (the ordered history of combos used), `created_at`/
`updated_at` timestamps, `turns` (the count of completed replies, stamped
on save for the picker), and `assets` (the manifest of content-addressed photo
files the session references). yap writes the model fields only on `:Yap` and
`:YapChangeModel` — never during a send, so the append-only rule holds
(R-blank-lines) — and
stamps `updated_at` on every save (one line after the turn, not per-reply
metadata). It reads the frontmatter on open and surfaces it in the
`:YapSessions` picker. Token/cost totals are deliberately NOT frontmatter:
they accumulate in per-buffer memory for the winbar and reset on reopen. The
earlier frontmatter design got this wrong by folding per-reply usage into the
header, which made every metadata update a non-local buffer edit that fought
R-blank-lines.

#### R-templates-skills — Templates and skills are plain markdown files inserted into the buffer

`templates_dir` files append as a `# @user` message: a body with no leading
heading is wrapped automatically; a leading `# @role` heading (including
`# @user`) is used as-is to set the role, and append_message reuses the
trailing heading when it already has that role, so a `# @user` heading never
duplicates. `skills_dir` files merge into the `# @system` message and so carry
no `# @user`/`# @assistant` headings of their own (except an agent skill that
quotes the message format). A skill's optional frontmatter may carry
`description:` for the skills intro (skills_intro) and is stripped on insert.
Nothing is auto-loaded and nothing is hidden: the inserted text is visible,
editable buffer content like any other, and the intro is a short visible list,
never injected bodies. Why: the buffer stays the only state (R-buffer-only-state), and
templates/skills are just text, so one insert command covers compaction,
snippets and skills.

#### R-scratch-sections — Scratch sections are parsed from the live `notes.md` buffer, never re-read from the saved file during dispatch

`# @notes` is an inert backlog; `# @steer` is a replaceable pending message
that remains in the buffer until delivery (or follow-up dispatch), and the
whole `# @queue` body is one message, sent and cleared on `<C-s>`.
Editing/removing a pending steer sends an update/cancellation to the running
backend. Queue removal and delivered-steer removal are reflected in the buffer
and saved to the sidecar. The three sections fold independently. Why: pending
work is retractable, and the visible buffer — not a stale disk snapshot — is
the control surface.

### Backend and wire protocol

#### R-plain-text-only — The binary emits plain text and yap markers only

No ANSI, no padding, no rendering. Why: markdown rendering is the user's
ft=markdown setup; cell-based TUIs break Neovim yanking.

#### R-goai-adapter — Providers go through the GoAI SDK behind Yap's own adapter

Native OpenAI (Responses API), Anthropic, Google/Gemini and DeepSeek, plus any
OpenAI-compatible /chat/completions endpoint (Moonshot/Kimi, OpenRouter,
z.ai, local servers) via the compat provider. The stdout wire protocol is
unchanged: plain text and yap markers.

### Tools and audit trail

#### R-tool-region — One buffer region = one tool call+result pair

A yap:tool region holds the call (single-line JSON header) and the result text
together; parsing flattens the region into plain assistant transcript text
(tool name, JSON arguments, result). Deleting or editing the region edits that
transcript directly, so persisted history never carries native
tool_calls/tool messages — those exist only in memory during a single send.
Result content policy: edit/write tools return short confirmations, read-like
tools return truncated content (pi: 2000 lines / 50KB); pretty payloads
(diffs) go in parse-excluded yap:ui subsections. write/edit headers are slimmed
at emission time (`[N lines]` for content, `[N edits, +A/-B lines]` for
edits): the header is the tool name and JSON arguments the model sees flattened
into its history, and kilobytes of file content there buy nothing the yap:ui
diff and the file on disk don't already show (Anthropic's clear_tool_inputs is
the same idea); the full arguments are in the audit log. Old result bodies can
be cleared explicitly with `:YapClear`.

#### R-no-mcp — No MCP

The author's tools are thin HTTP wrappers that are less code as native Go
functions than an MCP client; MCP also has no equivalent of pi's hook bus. If
ever needed, add mark3labs/mcp-go additively.

#### R-compiled-tools — Tools are compiled-in Go files, one per file in agent/tools/

Each file self-registers via init(); adding a tool = adding a file and
recompiling. Not config files (the author wants tool code, not opaque
declarations), not external executable tool plugins: the tool interface is
compiled in, although individual tools may spawn subprocesses. bash, python and
ssh are deliberately unsandboxed — the author runs pi the same way and accepts
the residual risk — but are no longer unconfirmed: a conservative denylist of
irreversible / high-blast-radius operations (remote content piped into a
shell, rm -rf, mkfs/dd onto block devices, sudo, git push --force / reset
--hard / clean -f, chmod -R / chown -R, redirects onto system or secret paths,
shutdown/reboot, fork bombs; for python, subprocess/os.system/... and
shutil.rmtree) pauses the turn for an explicit human Run/Deny before the
command executes. Denial, timeout, and the absence of a serve process (yap
send) all deny. This is a prompt-injection mitigation, NOT a security
boundary: the denylist is bypassable. A real sandbox, if ever wanted, is
bubblewrap (Codex's Linux choice), not command-pattern allowlists (documented
as bypassable). bash and python accept an opt-in `isolate_network` flag that
runs the command in a fresh `unshare --user --map-root-user --net` namespace:
a deterministic network cutoff (no outbound or loopback connectivity) for
running commands offline — a model-requestable constraint, and the natural
place for the alert gate to force isolation when it flags an exfiltration.
curl and fetch deliberately do not: they exist to reach the network, so
isolating them would only ever fail. bash, curl and fetch accept an opt-in
`vpn` flag that runs the command or request inside a VPN network namespace: the
entry command is the `vpn.command` argv prefix in ~/.config/yap.json (e.g.
["/run/wrappers/bin/tunnel"], or ["sudo", "-n", "ip", "netns", "exec",
"mullvad"]), so any VPN setup that can be entered by a command works without
recompiling. On bash, `vpn` and `isolate_network` are mutually exclusive.
bash/python's operational mechanics are unchanged: own process
group, group kill on timeout and on `:YapStop`, tail-truncation, closed stdin.

#### R-live-output-audit — Live tool output never enters the session buffer

The buffer is the parseable conversation document (R-buffer-only-state); streaming command
output into it forces incremental escaping, dangling-region repair and
post-turn dedup (the yap:stream/keepstream design this rule replaced). Instead
each session has ONE persistent audit view (yap://<session>-audit): bash/python
announce their temp log via a yap:event stderr line, the Lua side drains new
bytes into the audit view (a `$ command` header per call), and `:YapLive` opens
it. The drained bytes are recorded in the audit log as `output` events, and the
audit view is rebuilt from that log on reopen — there is no separate audit-view
file. The session buffer only gets one-shot, append-only writes: the tool
header when the call commits, the result when it finishes. Normal streaming is
append-only; explicit document operations may rewrite existing content:
`:YapClear` replaces old tool result bodies with a pointer to the audit log
(path plus the exact line range holding that call's record), `:YapCompact` can
delete superseded history after confirmation, frontmatter changes with the
selected model, and the transient yap:usage marker is consumed into in-memory
totals. Why: output exists in exactly one place at any moment, and the buffer
format has no transient states to repair.

#### R-audit-log — The audit log is the durable record of everything the context doesn't carry

`audit.jsonl` beside the session markdown (in its own
`<cwd-slug>/<session>/` directory, `<session>/session.md`), JSON Lines (one timestamped JSON object per line),
append-only, written by the Lua side from yap:event lines plus synthesized
`output` events for streamed bash/python output: full tool arguments, streamed
bash/python output, full results, `attachment` events for image imports
(success metadata or the failure), and one journal line per turn (model,
tokens, cost, ms). The per-session directory is kept mode 0700 and
the session markdown, notes, and audit log files mode 0600 — transcripts and
tool output routinely contain secrets, so nothing in the session directory is
world-readable. The audit view (`:YapLive`) renders these
events and is rebuilt from the file on reopen; the audit file is the
authoritative record and survives restarts. A `:file` rename moves the log to
match the new name; a `:saveas` copy copies it, so the original session keeps
its own history. This is what makes slimmed headers
(R-tool-region) and `:YapClear` lossless.

### Neovim presentation and turn lifecycle

#### R-error-surface — Errors surface three ways

`vim.notify` (transient), winbar error state (persistent until next send), and
a parse-excluded buffer marker (record). Spawn failures of the binary are
caught and reported the same way.

#### R-folding — Folding is a projection of anchored structural units

Each window owns its view (initially 2) and open/closed choices. View 1 folds
system and assistant messages, including the newest; view 2 folds system and
regions; view 3 removes folds. Explicit view keys reset this window only.
Native commands and Tab share state. New folds follow defaults, not
neighbours; growing folds retain the user's choice. A mouse click on a closed
fold opens it (the same state as Tab); clicks on open content stay native.
Identity survives position
changes and undo through extmarks. Streaming updates text and fold ranges
synchronously before yielding; incomplete marker prefixes are buffered until
classifiable. Hidden sessions are reconciled synchronously on window entry.
Unchanged ranges are not recreated. Arbitrary edits/undo reconcile too.
Cursor/scroll restoration is distinct from the explicit follow-tail behavior.
The winbar displays the applied view, not the number of currently open folds.

#### R-async-stream — Streaming appends at the end of the buffer, fully async

gptel-style: the buffer stays editable while a reply streams in. Editing above
the streaming reply is safe; typing inside/below it interleaves with the
stream. Accepted trade-off; the fix (extmark insertion point) is documented as
future work, not done.

A window whose cursor sits on the last line FOLLOWS the stream (the Lua side
re-pins the cursor to the end after every append; Neovim never scrolls a window
for an API edit, so without that the view only tracked the end while a chunk
happened to land exactly on the cursor, i.e. while the last line was empty, and
then stranded it mid-reply). A window scrolled away is NEVER dragged during
the stream, and nothing moves from a non-normal mode. (The one deliberate
exception, unchanged: a completed turn puts the cursor on the new `# @user`
heading, so the next prompt is ready to type.)

#### R-turn-complete-event — Turn completion is a first-class event

When the binary exits successfully, the Lua side emits `User YapTurnDone` with
`data = { buf, turn }` (turn is the binary's `turn_end` payload when usage was
reported: model, prompt, completion, cost, ms). Hard backend/spawn errors do
not emit the event. A successful binary exit can still contain an agent error
marker (for example an empty completion or the tool-iteration bound); that
state is surfaced as an error and the default completion notification is
suppressed. The default handler (installed by setup(), disabled with
`notify_done = false`) calls vim.notify — only for a buffer not visible in any
window, and never on the error path, which already notifies (R-error-surface). Delegated
child results and failures are reported to the running parent, not toasted
separately; a direct child follow-up can notify normally. A completed turn sets
the awaiting hint, which drives the `󰫁N` rollup counting the OTHER awaiting
buffers (the buffer's own winbar shows the waiting icon): an imperative UI hint
like `errors`/`yap_usage`, not conversation state (R-buffer-only-state); reopened sessions seed
the rollup from their content on open. Why: herdr's "working → blocked → idle"
notification is a completion *event*, and an autocmd is the Neovim-native hook
for it (noice/nf-notify, chaining a next send) instead of a hardcoded side
effect.

## Lua <-> Go protocol (implementation reference)

- **stdin** — one JSON line per turn: `{"provider":"...","model":"...","messages":[...]}`
  (roles `system`/`user`/`assistant`; persisted tool regions arrive flattened
  as assistant transcript text). Explicit user `![FILE: name](file:///...)`
  references stay in Markdown and Go converts them into ordered image parts
  when sending; binary data is never in the session or stdin.
- **argv** — `yap serve` (one persistent process per session buffer).
- **stdout** — raw assistant text, streamed; thinking, tool regions and usage
  wrapped in yap markers. Each turn ends with an RS-prefixed
  `yap:turn_end {"ok":true|false,"error":?}` line (not buffer text). A turn is
  complete once the corresponding stderr `turn_complete` barrier is received,
  so audit events cannot lag behind completion. `yap send --provider NAME
  --model MODEL` remains available for one-off calls (e.g. generating a
  session description).
- **stderr** — error message, exit 1. Also carries `yap:event {json}` progress
  lines; the Lua side timestamps each one, appends it to the audit log, and
  renders it into the audit view:

  - `tool_start` `{"type","name":"bash"|"python","log","command"}` — the tool's
    output streams into `log`; the audit view follows it for live output.
  - `tool_end` `{"type","name":"bash"|"python","log","truncated"}` — the
    tool's log is complete; the Lua side drains the final bytes and removes
    the untruncated temp log.
  - `tool_call` `{"type","name","args"}` — every tool before it runs, full
    arguments (the buffer header keeps only slimmed write/edit args, R-tool-region).
  - `tool_result` `{"type","name","bytes","result"}` — full result.
  - `approval_request` `{"type","id","command"}` — a dangerous command pauses
    the turn; the Lua side prompts and replies
    `{"type":"approval_result","id","approved"}` on stdin.
  - `approval_timeout` `{"type","id"}` — the user never answered; denied.
  - `retry` `{"type","attempt","delay_ms","error"}` — a transient generation
    error (429/5xx/network) was retried before any output was emitted.
  - `turn_end` `{"type","model","prompt","completion","context_prompt",?,"cost",?,"context_window",?,"ms"}`
    — one per completed send.

  The Lua side also synthesizes `output` events (streamed bash/python output
  chunks) as it drains the temp log, so the audit log carries live output, not
  just the final result. The rest is error text.

The binary runs the agent loop internally: when the model requests tool calls
it executes them (compiled-in tools), emits one yap:tool region per pair, and
re-sends until the final answer or the iteration bound. In-memory only (never
persisted), each iteration appends the exact assistant message parts GoAI
produced — reasoning items/encrypted content, signatures, thought signatures,
reasoning_content — plus native tool-result messages, so tool continuation is
lossless within one process. The binary is pure Go (no cgo), built
CGO_ENABLED=0, using the GoAI SDK behind Yap's own agent/llm surface.
