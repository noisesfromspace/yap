## Contributor policy

No large refactors. Changes are kept narrowly scoped and local, so each one
is reviewable against the numbered rules below without sprawling across
modules. When a change would touch many areas, restructure code, or rework
behavior beyond the task at hand, do not edit this checkout in place: fork
the project first (copy it to a separate directory) and make the change
there, with permission of user. This applies to **AI agents**.

## Lua <-> Go protocol

- **stdin** — one JSON line per turn: `{"provider":"...","model":"...","messages":[...]}`
  (roles `system`/`user`/`assistant`; persisted tool regions arrive flattened
  as assistant transcript text).
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
    arguments (the buffer header keeps only slimmed write/edit args, R12).
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

## Business rules

The invariants below are the design contract of this plugin. Each rule exists
for a reason; change the code and the rule together. AI assistants editing
this repository MUST keep this section up-to-date.

### R1 — The buffer is the only conversation state

Neither the Lua side nor the Go binary may keep message state between turns.
Why: branching by deletion, prefill by editing, and undo-tree navigation only
work if the buffer is the single source of truth.

### R2 — `<!-- yap:* -->` marker regions are never sent as buffer text

The parser skips them (thinking, error, usage, yap:ui) or flattens them
(yap:tool becomes plain assistant transcript text naming the tool, its JSON
arguments and result — the raw region text is still never sent). Why: thinking
or display payloads re-sent to the API pollute or break the conversation.
(Bug of record: the first error comment WAS sent back as assistant content.)

### R3 — Lines before the first heading are ignored

The session header lives there. The parser's flush must clear the accumulator
when no role is set. (Bug of record: pre-heading text was prepended to the
first message until this was fixed.)

### R4 — The binary emits plain text and yap markers only

No ANSI, no padding, no rendering. Why: markdown rendering is the user's
ft=markdown setup; cell-based TUIs break Neovim yanking.

### R5 — Providers go through the GoAI SDK behind Yap's own adapter

Native OpenAI (Responses API), Anthropic, Google/Gemini and DeepSeek, plus any
OpenAI-compatible /chat/completions endpoint (Moonshot/Kimi, OpenRouter,
z.ai, local servers) via the compat provider. The stdout wire protocol is
unchanged: plain text and yap markers.

### R6 — Adjacent same-role messages are merged on send; empty messages dropped

Why: providers require role alternation.

### R7 — Exactly one blank line between messages, enforced locally at every write

Structural appends (headings, error markers) go through `append_lines()`,
which trims trailing blanks and prepends exactly one blank line itself — never
append a heading with `append_text()`. The binary separates streamed tool
regions with blank lines. There is no buffer-wide normalize pass: sends never
rewrite existing lines, so what you see before ctrl-s is byte-identical to
what gets sent. Binary-emitted regions (thinking, tool regions, error markers)
carry no leading newlines and self-terminate with exactly one blank line; a
`pad()` in the agent loop bridges the two stateful transitions (heading → first
message, streamed text → first tool header).

(Bug of record: regions prepended `\n\n` while regions also ended in `\n`,
giving two blank lines between tool calls.)

Why: readable diffs, stable folds, gptel-like staticness. (Bug of record:
hand-rolled `"\n"` prefixes broke separation when trailing-blank trimming was
added; a buffer-wide normalize pass made every send rewrite the whole buffer
and churn fold state.)

### R8 — Sessions are plain markdown files; file operations are the session operations

The file is created at buffer creation so a fresh session is file-backed (and
nameable via `:file`) before the first reply. Saves follow every turn exit,
including errors and `:YapStop`, and go through `:write!` (not `writefile()`):
the buffer owns the file, so mtime bookkeeping, `:w`, and E13 all behave
normally. Every stream exit, including backend errors and `:YapStop`, repairs
any dangling streamed marker, appends a fresh `# @user` message, and saves that
final writable state. `save()` follows buffer renames so `:file` names and
`:saveas` forks. Why: no second serialization format to keep in sync. Session
buffers (and their audit view buffers) are unlisted — never in `:ls` or buffer
pickers — so navigation uses `<leader>r`, and a session's audit view opens with
`:YapLive`.

### R9 — Errors surface three ways

`vim.notify` (transient), winbar error state (persistent until next send), and
a parse-excluded buffer marker (record). Spawn failures of the binary are
caught and reported the same way.

### R10 — Folding is a projection of anchored structural units

Each window owns its view (initially 2) and open/closed choices. View 1 folds
system and assistant messages, including the newest; view 2 folds system and
regions; view 3 removes folds. Explicit view keys reset this window only.
Native commands and Tab share state. New folds follow defaults, not
neighbours; growing folds retain the user's choice. Identity survives position
changes and undo through extmarks. Streaming updates text and fold ranges
synchronously before yielding; incomplete marker prefixes are buffered until
classifiable. Hidden sessions are reconciled synchronously on window entry.
Unchanged ranges are not recreated. Arbitrary edits/undo reconcile too.
Cursor/scroll restoration is distinct from the explicit follow-tail behavior.
The winbar displays the applied view, not the number of currently open folds.

### R11 — Streaming appends at the end of the buffer, fully async

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

### R12 — One buffer region = one tool call+result pair

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

### R13 — No MCP

The author's tools are thin HTTP wrappers that are less code as native Go
functions than an MCP client; MCP also has no equivalent of pi's hook bus. If
ever needed, add mark3labs/mcp-go additively.

### R14 — The model state is durable YAML frontmatter; everything else is ephemeral

The frontmatter holds `provider`/`model` (the combo to resume with), `cwd` (the
exact working directory the session was created in — the session dir slug is
lossy), `models` (the ordered history of combos used), `created_at`/
`updated_at` timestamps, and `turns` (the count of completed replies, stamped
on save for the picker). yap writes the model fields only on `:Yap` and
`:YapChangeModel` — never during a send, so R7's append-only rule holds — and
stamps `updated_at` on every save (one line after the turn, not per-reply
metadata). It reads the frontmatter on open and surfaces it in the
`:YapSessions` picker. Token/cost totals are deliberately NOT frontmatter:
they accumulate in per-buffer memory for the winbar and reset on reopen. The
earlier frontmatter design got this wrong by folding per-reply usage into the
header, which made every metadata update a non-local buffer edit that fought
R7.

### R15 — Tools are compiled-in Go files, one per file in agent/tools/

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
as bypassable). bash/python's operational mechanics are unchanged: own process
group, group kill on timeout and on `:YapStop`, tail-truncation, closed stdin.

### R16 — Live tool output never enters the session buffer

The buffer is the parseable conversation document (R1); streaming command
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

### R17 — The audit log is the durable record of everything the context doesn't carry

`~/.yap/audit/<cwd-slug>/<session>.jsonl`, JSON Lines (one timestamped JSON
object per line), append-only, written by the Lua side from yap:event lines
plus synthesized `output` events for streamed bash/python output: full tool
arguments, streamed bash/python output, full results, and one journal line per
turn (model, tokens, cost, ms). The audit view (`:YapLive`) renders these
events and is rebuilt from the file on reopen; the audit file is the
authoritative record and survives restarts. This is what makes slimmed headers
(R12) and `:YapClear` lossless.

### R18 — Templates and skills are plain markdown files inserted into the buffer

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
never injected bodies. Why: the buffer stays the only state (R1), and
templates/skills are just text, so one insert command covers compaction,
snippets and skills.

### R19 — Turn completion is a first-class event

When the binary exits successfully, the Lua side emits `User YapTurnDone` with
`data = { buf, turn }` (turn is the binary's `turn_end` payload when usage was
reported: model, prompt, completion, cost, ms). Hard backend/spawn errors do
not emit the event. A successful binary exit can still contain an agent error
marker (for example an empty completion or the tool-iteration bound); that
state is surfaced as an error and the default completion notification is
suppressed. The default handler (installed by setup(), disabled with
`notify_done = false`) calls vim.notify — only for a buffer not visible in any
window, and never on the error path, which already notifies (R9). Delegated
child results and failures are reported to the running parent, not toasted
separately; a direct child follow-up can notify normally. A completed turn sets
the awaiting hint, which drives the `󰫁N` rollup counting the OTHER awaiting
buffers (the buffer's own winbar shows the waiting icon): an imperative UI hint
like `errors`/`yap_usage`, not conversation state (R1); reopened sessions seed
the rollup from their content on open. Why: herdr's "working → blocked → idle"
notification is a completion *event*, and an autocmd is the Neovim-native hook
for it (noice/nf-notify, chaining a next send) instead of a hardcoded side
effect.

### R20 — Scratch sections are parsed from the live `*.queue` buffer, never re-read from the saved file during dispatch

`# @notes` is an inert backlog; `# @steer` is a replaceable pending message
that remains in the buffer until delivery (or follow-up dispatch), and the
whole `# @queue` body is one message, sent and cleared on `<C-s>`.
Editing/removing a pending steer sends an update/cancellation to the running
backend. Queue removal and delivered-steer removal are reflected in the buffer
and saved to the sidecar. The three sections fold independently. Why: pending
work is retractable, and the visible buffer — not a stale disk snapshot — is
the control surface.
