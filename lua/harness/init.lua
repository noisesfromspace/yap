-- yap.nvim — the buffer is the conversation.
--
-- A yap buffer is plain markdown. Headings of the form `# @user`,
-- `# @assistant` and `# @system` delimit messages; everything between
-- headings is message content. The buffer is the ONLY state: deleting a
-- message removes it from the conversation, editing an assistant reply
-- changes what the model "said", inserting a fake reply steers it.
-- gptel semantics, Neovim native.
--
-- Sending serializes the whole buffer to the `yap` binary, which talks
-- to the provider and streams the reply back into the buffer.

local M = {}

local paths = require("harness.path")
local config = require("harness.config")
local picker = require("harness.picker")
local view = require("harness.view")

M.config = config.defaults

local state = require("harness.state")
local frontmatter = require("harness.frontmatter")
local winbar = require("harness.winbar")
local spinner = require("harness.spinner")
local drawer = require("harness.drawer")
local scratchmod = require("harness.scratch")
local describe = require("harness.describe")
local subagent = require("harness.subagent")
local template = require("harness.template")
local context = require("harness.context")
local guard = require("harness.guard")

M.winbar = winbar.winbar
M.overview = winbar.overview
M.steer = scratchmod.steer
M.scratch_send = scratchmod.scratch_send
M.scratch_foldexpr = scratchmod.scratch_foldexpr
M.scratch_toggle = scratchmod.scratch_toggle

-- Shared per-buffer state lives in harness.state; these aliases keep the
-- orchestration code reading like the pre-split module. The winbar reads
-- the same tables directly.
local running = state.running
local stopped = state.stopped
local live = state.live
local errors = state.errors
local last_turn = state.last_turn
local awaiting = state.awaiting
local steer = state.steer
local servers = state.servers
local subagent_children = state.subagent_children
local subagent_done = state.subagent_done
local pending_approvals = state.pending_approvals

local adopt
-- close_session is a request-scoped frontend side effect (like quickfix):
-- the agent asked to end the session, so the buffer is wiped once the turn
-- has fully completed and the session file has been saved.
local close_after_turn = {}

-- Honor a close_session request by wiping the buffer. The turn has already
-- been saved by whichever completion path reached this point.
local function close_if_requested(buf)
  if close_after_turn[buf] then
    close_after_turn[buf] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

-- Most-recently-focused buffers, front first. Session buffers are unlisted,
-- so Neovim's :bd/:bw/:close skip them when choosing where to land after
-- deleting the current buffer and drop the user on an empty "No Name"
-- buffer instead (the "deleting the last listed buffer" path). This order
-- redirects that landing back to the buffer the user came from.
local focus_mru = {}

local function focus_touch(buf)
  for i, b in ipairs(focus_mru) do
    if b == buf then
      table.remove(focus_mru, i)
      break
    end
  end
  table.insert(focus_mru, 1, buf)
end

local function focus_forget(buf)
  for i, b in ipairs(focus_mru) do
    if b == buf then
      table.remove(focus_mru, i)
      return
    end
  end
end

-- Landing spot after closing the current session: the most recently focused
-- session awaiting a reply, otherwise a running session, otherwise the last
-- ordinary file buffer. Idle sessions are not a landing spot.
local function focus_fallback(buf)
  -- A buffer already on screen in another window of this tab is not a
  -- landing spot: switching the current window to it would duplicate it
  -- across a split.
  local function shown(b)
    local tab = vim.api.nvim_get_current_tabpage()
    for _, w in ipairs(vim.fn.win_findbuf(b)) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_tabpage(w) == tab then
        return true
      end
    end
    return false
  end
  local function open(b)
    return b ~= buf
      and vim.api.nvim_buf_is_valid(b)
      and vim.api.nvim_buf_is_loaded(b)
      and not shown(b)
  end
  for _, b in ipairs(focus_mru) do
    if open(b) and vim.b[b].yap and awaiting[b] then
      return b
    end
  end
  for _, b in ipairs(focus_mru) do
    if open(b) and vim.b[b].yap and running[b] then
      return b
    end
  end
  for _, b in ipairs(focus_mru) do
    -- Only real, listed file buffers count. Explorers (mini.files, netrw),
    -- quickfix, terminal, help and other special windows are skipped so :bd
    -- never parks the cursor in one.
    if open(b)
      and not vim.b[b].yap
      and vim.bo[b].buftype == ""
      and vim.bo[b].buflisted
    then
      return b
    end
  end
  return nil
end

-- The plugin's install root, derived from this file's location on the
-- runtimepath, so the self-help hint below points at the real README/doc
-- wherever yap is installed instead of a hardcoded development path.
local yap_install_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

-- The harness's own boilerplate, always injected as the first system
-- message on every send. It is independent of agents_file (the user's
-- rules) and lives here so session files never store it.
local function yap_about(buf)
  local skills = template.skills_intro_lines()
  local agents = template.agents_intro_lines()
  local about = [[# About Yap

You are running inside Yap, an agent harness for Neovim. The conversation is an editable Markdown buffer and the source of truth: `# @system`, `# @user`, and `# @assistant` headings delimit messages; editing or deleting a message branches or rewrites history, and the visible transcript is what is re-sent. Never emit one of those headings or a `<!-- yap:` marker line in a reply; indent or fence it instead.

Between turns, tool calls and their results are plain text in the transcript, not re-executed or re-sent. When asked about Yap itself, read `README.md` / `doc/yap.txt` in the plugin (]] .. yap_install_root .. [[) rather than guessing.

For GitHub searches and reading GitHub code, repositories, issues, pull requests, files, or Projects, use the `github` tool rather than curl, fetch, websearch, bash, or `gh`. Use other tools only if the `github` tool cannot perform the needed operation; never pass the GitHub token in tool arguments.

## Skills

Skills are reusable on-demand instructions in Markdown files under ]] .. M.config.skills_dir .. [[ (`<name>.md`). Before working in a listed domain, `read` the matching skill file and follow it; read only what you need.]]
  if skills then
    about = about .. "\n\n" .. table.concat(skills, "\n")
  end
  about = about .. "\n\n" .. [[## Parallelism and background work

When you need several independent read-only results (read, search, glob, git, fetch, websearch, models, ls), request them all in one message — they run concurrently. Batch your reads: opening two files at once is faster than opening them one after another.

For independent slow work, `start_task` launches bash, fetch, or websearch in the background and returns a task ID. Launch the slow call, do other useful work, then call `wait_tasks` once to collect the result before relying on it. For example, start a long test run or build, then read files or research meanwhile. Tasks end within this turn; do not start commands that conflict with ongoing work.

## Subagents

Use `subagent` to delegate a self-contained subtask that is large or independent enough to benefit from an isolated context or a different model. It blocks until the child finishes and returns the child's answer and session path; inspect the child session for its full conversation. The `agent` argument names an agent from the `## Agents` list (definition files in `agents_dir`, default `~/.config/yap/agents/<agent>.md`). To ask a follow-up, pass `session` with that path and `task` with the question (omit `agent`); this appends a user turn to the same child, preserving its system prompt and history. Pass `model` as a `provider/model` combo to run the child on the model you judge appropriate — it overrides the agent definition's `model`. Discover combos with the `models` tool: with no filter it lists the configured providers and their model counts, and with a filter it lists matching `provider/model` combos plus their price per 1M tokens when known. Without `model` the child uses the definition's `model` (a bare model name there inherits the parent's provider) and otherwise your own combo. `model` is ignored on follow-ups.]]
  if agents then
    about = about .. "\n## Agents\n\nThe `agent` argument accepts one of:\n\n" .. table.concat(agents, "\n")
  end
  -- The agent needs the session's scratch location to write throwaway
  -- scripts and generated artifacts into the session instead of /tmp or the
  -- project. This prefix is the only per-send, per-buffer message, so the
  -- path is injected here rather than stored in the session file.
  local spath = buf and paths.session_path(buf)
  if spath then
    local sdir = vim.fn.fnamemodify(spath, ":h")
    about = about
      .. "\n\n## Session files\n\nThis session lives in `"
      .. sdir
      .. "`. Write throwaway Python scripts, generated artifacts (HTML, data dumps), fetched downloads, and quick-inspection clones into its `assets/` subfolder (`"
      .. sdir
      .. "/assets/`) — the same folder that holds images the conversation references — so they stay with the session, out of the project and /tmp, and you can find files you saved there earlier in the session."
  end
  return about
end

local function system_prompt()
  local f = io.open(M.config.agents_file, "r")
  if f then
    local text = f:read("*a")
    f:close()
    text = text:gsub("%s+$", "")
    if text ~= "" then
      return text
    end
  end
  return M.config.system
end

local HEAD = "^# @(%a+)%s*$"
local document = require("harness.document")
local fold = require("harness.fold")
local audit = require("harness.audit")

-- Frontmatter read/write (end_line, parse, render, sync, record_subagent)
-- lives in harness.frontmatter.

-- Conversation document parsing/appending lives in harness.document.

-- Templates and skills live in harness.template.

function M.parse_buffer(buf)
  return document.parse_buffer(buf)
end
function M.insert(name, opts)
  return template.insert(name, opts)
end
function M.template_names()
  return template.template_names()
end
function M.insert_file(opts)
  return template.insert_file(opts)
end

--- Evaluate a visual selection through the model (one-shot, no tools): the
--- selected lines are replaced by the model's output. See |:YapEval|.
function M.eval(opts)
  return require("harness.eval").eval(opts)
end

--- Open an interactive eval session about a selection, kept out of the
--- session picker. The source buffer is not changed. See |:YapEval|.
function M.eval_session(opts)
  return require("harness.eval").session(opts)
end

function M.is_running(buf)
  return state.is_running(buf)
end

-- ─── Send ──────────────────────────────────────────────────────────────────

-- One persistent serve backend per session buffer, so several sessions can
-- stream at once. Each backend keeps its own tool state (SSH connections
-- above all) for the life of its buffer; a stopped process is restarted
-- on the next send. `servers` lives in harness.state (shared with the
-- subagent and scratch modules).

-- buf → flush function: flushes streamed stdout that has been buffered for
-- a redraw tick into the buffer. The send path coalesces per-token stdout
-- flushes into one edit per ~STREAM_FLUSH_MS so a fast model streaming
-- many tokens a second does not force Neovim to recompute expr folds once
-- per token (O(n) per edit on large sessions).
local stream_flush = {}

-- The audit log write, live tool tail, session-usage seed, and log drain
-- all live in harness.audit.

local follow_override = {} -- session buf -> windows deliberately focused during a turn (paused tail-following)
local live_session_label

local function answer_approval(buf, approved)
  local ev = pending_approvals[buf]
  if not ev then
    return
  end
  pending_approvals[buf] = nil
  local process = servers[buf]
  if process then
    -- backend stopped or timed out; never approve a stale call
    process:write(vim.json.encode({ type = "approval_result", id = ev.id, approved = approved }) .. "\n")
    audit.append_event(
      buf,
      { type = "approval_result", id = ev.id, approved = approved, ts = os.date("%Y-%m-%dT%H:%M:%S") }
    )
  end
  -- Re-render after the result is written (and pending cleared) so an answered
  -- approval re-renders as settled (granted/denied) in Guard instead of
  -- vanishing from the board.
  guard.touch()
end
M.answer_approval = answer_approval

-- Approval is a non-blocking notification, not a modal: the turn is parked
-- (the backend waits up to five minutes) and the user answers deliberately
-- via :YapGuard. Distinct from the advisory toast by level, title and
-- shield icon so an action-required pause is never mistaken for a warning
-- about a call that already ran.
local function notify_approval(buf, ev)
  local risk = ev.risk or ""
  local lines = {
    ("yap: %s needs approval — %s: %s"):format(
      live_session_label(buf),
      ev.tool or "tool",
      ev.reason or "review call"
    ),
  }
  if risk ~= "" then
    lines[#lines + 1] = risk
  end
  vim.notify(
    table.concat(lines, "\n"),
    vim.log.levels.ERROR,
    { title = "yap approval required", icon = M.config.icons.approval }
  )
end

local function handle_event(buf, json_line)
  local ok, ev = pcall(vim.json.decode, json_line)
  if not ok or type(ev) ~= "table" then
    return
  end
  ev.ts = os.date("%Y-%m-%dT%H:%M:%S")
  if ev.type == "tool_start" and ev.log then
    local logs = state.live_logs[buf] or {}
    state.live_logs[buf] = logs
    logs[ev.log] = { name = ev.name or "tool", log = ev.log, since = os.time(), offset = 0, pending = "" }
    live[buf] = logs[ev.log]
    audit.tool_start(buf, ev.command or ev.name or "tool")
  elseif ev.type == "tool_end" then
    audit.drain(buf) -- the log is complete; capture the final bytes
    audit.flush(buf, ev.log) -- emit any unterminated final line
    local logs = state.live_logs[buf] or {}
    logs[ev.log] = nil
    live[buf] = next(logs) and select(2, next(logs)) or nil
    -- Go keeps the log for us; once drained, an untruncated one is gone
    -- (a truncated log stays: its result references it).
    if ev.log and not ev.truncated then
      vim.npcall(os.remove, ev.log)
    end
  elseif ev.type == "subagent_request" then
    subagent.start(buf, ev)
  elseif ev.type == "subagent_timeout" then
    local child = subagent_children[buf]
    if child then
      M.stop(child)
    end
  elseif ev.type == "approval_request" then
    audit.append_event(buf, ev)
    pending_approvals[buf] = ev
    if state.auto_accept then
      answer_approval(buf, true)
    else
      notify_approval(buf, ev)
      guard.touch()
    end
  elseif ev.type == "approval_timeout" then
    pending_approvals[buf] = nil
    audit.append_event(buf, ev)
    guard.touch()
  elseif ev.type == "alert_advisory" then
    -- Advisories are silent: recorded for the guard board's Advisory section
    -- (and the audit log) but never toasted. The board is the audit surface.
    audit.append_event(buf, ev)
    guard.touch()
  elseif ev.type == "tool_call" then
    -- quickfix is a frontend side effect: only a live tool_call event
    -- creates a list, so persisted tool regions never replay on reopen.
    if ev.name == "quickfix" then
      local ok_qf, a = pcall(vim.json.decode, ev.args or "")
      if ok_qf and type(a) == "table" and type(a.entries) == "table" then
        local items = {}
        for _, entry in ipairs(a.entries) do
          table.insert(items, {
            filename = entry.file,
            lnum = entry.line,
            col = entry.column or 0,
            text = entry.text,
          })
        end
        -- ' ' creates a new stack entry: it replaces the visible list while
        -- preserving the previous one for :colder/:cnewer.
        vim.fn.setqflist({}, " ", { title = "Yap", context = { yap = true }, items = items })
      end
    elseif ev.name == "close_session" then
      -- Defer to turn completion so the reply streams out and the session
      -- file is saved before the buffer is wiped (complete() below).
      close_after_turn[buf] = true
    end
    audit.append_event(buf, ev) -- full arguments for every tool (bash renders via tool_start)
  elseif ev.type == "tool_result" then
    audit.append_event(buf, ev) -- full result; bash output already streamed above
  elseif ev.type == "task_start" or ev.type == "task_end" then
    audit.append_event(buf, ev)
  elseif ev.type == "retry" then
    audit.append_event(buf, ev) -- a transient generation error was retried
  elseif ev.type == "steer" then
    if steer[buf] == ev.text then
      steer[buf] = nil -- delivered: remove only the matching live draft
      local scratch = vim.b[buf].yap_scratch
      if scratch and vim.api.nvim_buf_is_valid(scratch) and scratchmod.section_text(scratch, "steer") == ev.text then
        scratchmod.set_section(scratch, "steer", {})
        scratchmod.save(scratch)
      end
    end
    audit.append_event(buf, ev) -- audit trail: a steering message landed mid-turn
  elseif ev.type == "model_change" then
    audit.append_event(buf, ev) -- audit trail: a model switch landed mid-turn
  elseif ev.type == "tool_text_warning" then
    audit.append_event(buf, ev) -- the model emitted a tool call as text; nothing ran
  elseif ev.type == "usage" then
    state.live_usage[buf] = ev
    vim.cmd.redrawstatus()
  elseif ev.type == "turn_end" then
    state.live_usage[buf] = nil
    last_turn[buf] = ev -- for the User YapTurnDone event on exit
    -- The audit log is the single source of truth for usage: this folds the
    -- turn into both the since-open and all-time totals (see audit.lua).
    audit.apply_turn_end(buf, ev)
    -- An advisory that fired mid-turn is on disk now; re-render the board so
    -- it reflects the settled turn even if its own touch() raced the event.
    guard.touch()
  end
end

--- :YapClear [keep] — replace the bodies of all but the last `keep`
--- (default 2) yap:tool regions with a placeholder; the full output
--- stays in the audit log. Headers (flattened into the model's transcript)
--- and yap:ui diffs stay. This is the one sanctioned rewrite of
--- existing lines (R-live-output-audit): the user owns the document, and clearing old
--- tool output is what keeps long sessions inside the context window.
function M.clear(buf, keep)
  buf = (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
  if running[buf] then
    vim.notify("yap: turn running; stop it before clearing old tool output", vim.log.levels.WARN)
    return
  end
  keep = keep or 2
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- Map tool-call ids to their JSONL line range (tool_call → tool_result)
  -- so each placeholder can point at the exact lines it replaced.
  local by_id = {}
  local apath = paths.audit_path(buf)
  if vim.fn.filereadable(apath) == 1 then
    for n, line in ipairs(vim.fn.readfile(apath)) do
      if line ~= "" then
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" and ev.id then
          local entry = by_id[ev.id]
          if not entry then
            entry = {}
            by_id[ev.id] = entry
          end
          entry.first = entry.first or n
          entry.last = n
        end
      end
    end
  end
  local function ref_for(id)
    local entry = id and by_id[id] or nil
    if entry and entry.last then
      if entry.first and entry.first ~= entry.last then
        return ("%s:%d-%d"):format(vim.fn.fnamemodify(apath, ":~"), entry.first, entry.last)
      end
      return ("%s:%d"):format(vim.fn.fnamemodify(apath, ":~"), entry.last)
    end
    return vim.fn.fnamemodify(apath, ":~") .. ":?"
  end
  -- collect tool regions as { first body line, last body line, header } (1-based,
  -- inclusive); the body runs from after the header to the yap:ui
  -- opener or the region closer
  local regions = {}
  local i = 1
  while i <= #lines do
    local body_start, header
    if lines[i]:match("^<!%-%- yap:tool .+ %-%->%s*$") then
      header = lines[i]:match("^<!%-%- yap:tool (.+) %-%->%s*$")
      body_start = i + 1 -- single-line header
    elseif lines[i]:match("^<!%-%- yap:tool%s*$") then
      local acc = {}
      local j = i + 1 -- multi-line header: body after its closing -->
      while j <= #lines and not lines[j]:match("^%-%->%s*$") do
        acc[#acc + 1] = lines[j]
        j = j + 1
      end
      header = table.concat(acc, "\n")
      body_start = j + 1
    end
    if body_start then
      local j = body_start
      while j <= #lines and not lines[j]:match("^<!%-%- yap:ui") and not lines[j]:match("^<!%-%- /yap:tool") do
        j = j + 1
      end
      table.insert(regions, { body_start, j - 1, header = header })
      i = j
    else
      i = i + 1
    end
  end
  local cleared = 0
  for r = 1, #regions - keep do
    local s, e = regions[r][1], regions[r][2]
    if e >= s and not lines[s]:match("^%[output cleared") then
      local id
      local ok_h, h = pcall(vim.json.decode, regions[r].header or "")
      if ok_h and type(h) == "table" then
        id = h.id
      end
      local placeholder = ("[output cleared — full output in the audit log: %s]"):format(ref_for(id))
      vim.api.nvim_buf_set_lines(buf, s - 1, e, false, { placeholder })
      cleared = cleared + 1
      local delta = (e - s + 1) - 1 -- replaced that many lines with one
      for r2 = r + 1, #regions do
        regions[r2][1], regions[r2][2] = regions[r2][1] - delta, regions[r2][2] - delta
      end
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
  if cleared > 0 then
    require("harness.session").save(buf)
  end
end

--- The compaction prompt: a `compact` template in templates_dir overrides
--- the built-in default (compaction is the template mechanism applied,
--- R-templates-skills). Returns trimmed body lines, never a leading # @role heading.
local function compact_prompt_lines()
  local lines = template.named_lines("compact")
  if not lines then
    lines = vim.split(
      "Summarize the conversation above into a compact markdown summary that\n"
        .. "preserves all facts, decisions, open todos, and current file state.\n"
        .. "I will use that summary to continue the conversation with full context.",
      "\n",
      { plain = true }
    )
  end
  vim.list_extend(lines, {
    "Do not use the colon character anywhere in the summary. Avoid YAML/frontmatter delimiters, Markdown headings, code fences, and HTML comments. Use simple prose or basic bullets so the summary stays safe for Markdown Tree-sitter parsing.",
  })
  return lines
end

--- :YapCompact — compaction as the visible, editable recipe, automated:
--- insert the compact prompt, send it, then offer to delete the superseded
--- history once the summary has streamed in. The summary stays a visible
--- # @assistant turn; the deletion is an ordinary (undoable) buffer edit,
--- never a hidden archive (see |yap-compact|).
function M.compact()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.b[buf].yap then
    vim.notify("yap: not a yap buffer", vim.log.levels.WARN)
    return
  end
  if running[buf] then
    vim.notify("yap: turn running; stop it before compacting", vim.log.levels.WARN)
    return
  end
  template.append_as_message(buf, compact_prompt_lines())
  vim.b[buf].yap_compact_pending = true
  M.send()
end

--- Offer to drop the history the summary superseded (asked once the
--- summary has finished streaming; the summary is never touched).
function M.compact_offer(buf)
  vim.ui.select({ "Delete history", "Keep history" }, {
    prompt = "yap: compact — delete the superseded history? (the summary stays)",
  }, function(choice)
    if choice == "Delete history" then
      M.compact_delete(buf)
    end
  end)
end

--- Delete every message between the system message and the final summary
--- (the last # @assistant message), leaving frontmatter + system message +
--- summary + the trailing # @user prompt. Blank-line separation is R-blank-lines.
function M.compact_delete(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ai
  for i = #lines, 1, -1 do
    if lines[i]:match("^# @assistant%s*$") then
      ai = i
      break
    end
  end
  if not ai then
    vim.notify("yap: no assistant summary to keep", vim.log.levels.WARN)
    return
  end
  -- Keep frontmatter + the system message: the system message ends at the
  -- first heading after # @system; with no system message, keep only the
  -- frontmatter (everything before the first heading).
  local se = 0
  for i = 1, #lines do
    if lines[i]:match("^# @system%s*$") then
      for j = i + 1, #lines do
        if lines[j]:match(HEAD) then
          se = j - 1
          break
        end
      end
      if se == 0 then
        se = #lines -- system message runs to the end (no later heading)
      end
      break
    elseif lines[i]:match(HEAD) then
      se = i - 1 -- no system message: keep frontmatter only
      break
    end
  end
  while se > 0 and lines[se]:match("^%s*$") do
    se = se - 1
  end
  local kept = {}
  for i = 1, se do
    kept[#kept + 1] = lines[i]
  end
  kept[#kept + 1] = "" -- one blank line between system and summary (R-blank-lines)
  for i = ai, #lines do
    kept[#kept + 1] = lines[i]
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, kept)
  require("harness.session").save(buf)
end

-- Drawer open/close lives in harness.drawer.

-- Close the session's drawers. `scratch`/`audit_buf` are the drawer buffers
-- captured while `buf` was still loaded: :bd unloads the session before a
-- deferred callback runs, clearing vim.b[buf].yap_scratch, so the callback
-- must not re-read it from the buffer.
local function close_session_drawers(buf, scratch, audit_buf)
  if not scratch and vim.api.nvim_buf_is_valid(buf) then
    scratch = vim.b[buf].yap_scratch
  end
  if scratch and vim.api.nvim_buf_is_valid(scratch) then
    drawer.close(scratch, buf)
  end
  if not audit_buf then
    local t = audit.view(buf)
    audit_buf = t and t.bufnr
  end
  if audit_buf and vim.api.nvim_buf_is_valid(audit_buf) then
    drawer.close(audit_buf, buf)
  end
end

--- The session buffer a yap panel belongs to: a session buffer itself, the
--- live tail's owning session, or the scratch/guard board's recorded
--- `yap_owner`. Returns nil for a buffer that is not part of any session.
function M.session_of(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  if vim.b[buf].yap then
    return buf
  end
  for owner, t in pairs(audit.views()) do
    if t.bufnr == buf then
      return owner
    end
  end
  local owner = vim.b[buf].yap_owner
  if owner and vim.api.nvim_buf_is_valid(owner) and vim.b[owner].yap then
    return owner
  end
  return nil
end

--- The session's live tail buffer, or nil before it has been created (used to
--- detect whether the tail is on screen without forcing it into existence).
function M.tail_buffer(buf)
  local t = audit.view(buf)
  return t and t.bufnr or nil
end

--- Open the session's live tool tail (:YapLive): one persistent read-only
--- buffer that follows the running tool's output. Opens even before any tool
--- has run (an empty tail that fills as tools execute). The tail stacks below
--- the guard board when it is open in this tab, else below the session window
--- — the canonical session → guard → log column.
function M.live(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local owner = M.session_of(buf)
  if not owner then
    vim.notify("yap: live tool tail needs a yap session", vim.log.levels.WARN)
    return
  end

  local t = audit.ensure(owner)
  local anchor = drawer.win_in_tab(guard.buf(), vim.api.nvim_get_current_tabpage())
  local split = "below"
  if not anchor then
    anchor = drawer.owner_window(owner)
  end

  if not drawer.open_at(t.bufnr, drawer.half_screen(), nil, split, anchor) then
    return
  end
  audit.refresh(owner) -- a rule drawn while hidden may not match this window's width
  if M.config.keymaps.live ~= "" then
    vim.keymap.set("n", M.config.keymaps.live, function()
      M.live(t.bufnr)
    end, { buffer = t.bufnr, silent = true, desc = "yap: toggle live tool output" })
  end
  vim.keymap.set("n", "q", function()
    M.live(t.bufnr)
  end, { buffer = t.bufnr, silent = true, desc = "yap: close live view" })
  if M.config.keymaps.guard ~= "" then
    vim.keymap.set("n", M.config.keymaps.guard, function()
      guard.toggle()
    end, { buffer = t.bufnr, silent = true, desc = "yap: guard board" })
  end
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(t.bufnr), 0 })
end

--- Focus the matching tool region in the session. The audit records calls
--- even if the user later edits their transcript, so a missing region simply
--- leaves the session cursor where it was. `call` is the { id, occurrence }
--- of the tool call to reveal.
local function focus_alert_call(buf, call)
  if not call then
    return
  end
  local win = vim.fn.win_findbuf(buf)[1]
  if not win then
    return
  end
  local seen = 0
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, detail in ipairs(require("harness.structure").parse(buf).regions) do
    if detail.kind == "tool" then
      local id
      for i = detail.start, math.min(detail.start + 4, #lines) do
        id = lines[i]:match('"id"%s*:%s*"([^"\\]+)"')
        if id or lines[i]:find("-->", 1, true) then
          break
        end
      end
      if id == call.id then
        seen = seen + 1
        if seen == call.occurrence then
          -- A guard-board inspection wins over tail-following for this turn.
          local paused = follow_override[buf]
          if paused then
            paused[win] = true
          end
          vim.api.nvim_win_call(win, function()
            vim.api.nvim_win_set_cursor(win, { detail.start, 0 })
            vim.cmd("normal! zvzz")
          end)
          return
        end
      end
    end
  end
end

-- Forward-declared: M.reveal_call below calls focus_buf before its
-- definition later in this file (a Lua local is only visible after its
-- declaration, so without this the call would resolve to a nil global).
local focus_buf

--- Open a session and focus the tool region a guard row points at. `call` is
--- the { id, occurrence } of the tool call (nil for rows without one). The
--- guard board's Inspect action uses this for rows loaded from disk, whether
--- or not the session is already open.
function M.reveal_call(path, call)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    focus_buf(buf)
    adopt(buf, path)
  else
    buf = M.open(path)
  end
  focus_alert_call(buf, call)
end

-- The scratch queue and mid-turn steering live in harness.scratch.
--- parse-excluded marker in the buffer as a record.
local function report_error(buf, err)
  errors[buf] = err
  -- The marker is an HTML comment: neutralize any `-->` in the error
  -- text so it can't close the comment early for markdown renderers.
  local lines = { "<!-- yap:error" }
  vim.list_extend(lines, vim.split(err:gsub("%-%->", "-- >"), "\n", { plain = true }))
  table.insert(lines, "-->")
  document.append_lines(buf, lines)
  -- A delegated failure is returned to the running parent as a tool result;
  -- a direct follow-up in the child should still report its own error.
  local parent = vim.b[buf].yap_subagent_parent
  if not (parent and running[parent]) then
    vim.notify("yap: " .. err, vim.log.levels.ERROR)
  end
end

--- Close dangling regions left by an interrupted stream. :YapStop
--- kills the binary, which exits without emitting the closers for
--- whatever it was mid-way through: a thinking comment (close with
--- `-->`), a multi-line tool header (an unterminated comment: `-->`,
--- then the region closer), or a tool region whose header landed but
--- whose result didn't (`<!-- /yap:tool -->`). Two flags suffice:
--- model text/thinking and tool regions never interleave. Idempotent;
--- cheap enough to run on every process exit.
local function repair_stream_tail(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local in_tool, comment_open = false, false
  for _, line in ipairs(lines) do
    if line:match("^<!%-%- /yap:tool") then
      in_tool = false
    elseif line:match("^<!%-%- yap:tool%s*$") then
      in_tool, comment_open = true, true -- multi-line header comment
    elseif line:match("^<!%-%- yap:tool .+ %-%-%>%s*$") then
      in_tool = true -- single-line header: comment closed, region open
    elseif line:match("^<!%-%- yap:%a+%s*$") then
      comment_open = true
    elseif line == "-->" then
      comment_open = false
    end
  end
  local repair = {}
  if comment_open then
    table.insert(repair, "-->")
  end
  if in_tool then
    table.insert(repair, "<!-- /yap:tool -->")
  end
  if #repair > 0 then
    vim.api.nvim_buf_set_lines(buf, #lines, #lines, false, repair)
  end
end

-- Session titling (description generation) lives in harness.describe.
--- remains in its file; template steering without a scratch gets copied to
--- the empty user prompt so it cannot silently disappear.
local function leave_undelivered_steer(buf)
  local text = steer[buf]
  steer[buf] = nil
  if not text then
    return
  end
  local scratch = vim.b[buf].yap_scratch
  -- A late user instruction outranks an agent's close_session request.
  close_after_turn[buf] = nil
  if scratch and vim.api.nvim_buf_is_valid(scratch) then
    scratchmod.save(scratch)
    vim.notify("yap: steer was not delivered; draft remains in scratch (send again with <C-s>)", vim.log.levels.WARN)
  else
    document.append_message(buf, "user", vim.split(text, "\n", { plain = true }))
    require("harness.session").save(buf)
    vim.notify("yap: steer was not delivered; draft is in the user prompt (send with <C-s>)", vim.log.levels.WARN)
  end
end

--- Every stream exit, including errors and :YapStop, hands the buffer back
--- to the user in the same writable shape as a successful turn.
local function close_stream(buf)
  repair_stream_tail(buf)
  document.append_lines(buf, { "# @user", "" })
  awaiting[buf] = true
  require("harness.session").save(buf)
  leave_undelivered_steer(buf)
  if subagent_done[buf] then
    local done = subagent_done[buf]
    subagent_done[buf] = nil
    done(false)
  end
end

--- Serialize the current buffer and stream the assistant reply into it.
function M.send(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if running[buf] then
    vim.notify("yap: turn already running; use :YapStop to interrupt it", vim.log.levels.WARN)
    return false
  end
  -- A close request is scoped to the turn that made it: a stale flag from
  -- a previous errored or stopped turn must not close a later turn.
  close_after_turn[buf] = nil

  -- Import standalone photo paths before parsing or starting the turn. The
  -- resulting reference is visible in the buffer and survives later sends.
  local imported, attach_err = require("harness.attachment").import_paths(buf)
  if not imported then
    vim.notify("yap: " .. attach_err, vim.log.levels.WARN)
    return false
  end
  local messages = document.parse_buffer(buf)
  if #messages == 0 then
    vim.notify("yap: no message to send; write under # @user", vim.log.levels.WARN)
    return
  end

  -- The harness's own boilerplate is a stable system prefix, kept first so
  -- it never perturbs the prompt cache. Transient environment context (cwd,
  -- git status) is appended to the trailing user message below instead.
  table.insert(messages, 1, { role = "system", content = yap_about(buf) })

  -- Label the session from the latest user message before transient context
  -- is appended, so the title model never sees cwd/git.
  describe.refresh(buf, "user", messages)

  local extra = context.snapshot()
  if extra then
    -- Append to the most recent user message: normally the trailing prompt,
    -- but a hand-written `# @assistant` prefill stays last so its prefill
    -- semantics survive.
    local target
    for i = #messages, 1, -1 do
      if messages[i].role == "user" then
        target = messages[i]
        break
      end
    end
    if target then
      target.content = target.content .. "\n\n" .. extra
    else
      messages[#messages + 1] = { role = "user", content = extra }
    end
  end

  errors[buf] = nil
  stopped[buf] = nil
  awaiting[buf] = nil
  -- provider/model come from the buffer vars (set by :Yap /
  -- :YapChangeModel), falling back to config; sync them so the winbar
  -- and this send agree.
  local provider, model = config.current_combo(buf)
  vim.b[buf].yap_provider = provider
  vim.b[buf].yap_model = model
  state.live_usage[buf] = nil

  -- A window already watching the end keeps watching it while the reply
  -- streams (follow_windows); one parked elsewhere is not dragged along.
  local follow = document.following_windows(buf)
  local expected_follow = {}
  local paused_follow = {}
  follow_override[buf] = paused_follow
  local function sync_followers()
    document.sync_followers(buf, follow, expected_follow, paused_follow)
  end
  local function follow_tail()
    document.follow_windows(buf, follow, expected_follow)
  end
  -- New assistant output adopts the current view: in view 1 it stays
  -- folded; in views 2/3 it is visible as it arrives.
  document.append_lines(buf, { "# @assistant", "" })
  follow_tail()
  -- Sends never touch existing fold state or rewrite existing lines: the
  -- buffer is always in its final format, streaming only appends at the end,
  -- and new folds adopt the view's 'foldlevel' as they appear.
  spinner.start()
  audit.poll_start()

  local process = servers[buf]
  if not process then
    local partial = ""
    local stderr_partial = ""
    local stderr_chunks = {}
    local status, barrier
    -- Coalesce rapid per-token stdout flushes into one buffer edit per
    -- ~STREAM_FLUSH_MS: region parsing is O(n) per edit, so batching keeps a
    -- fast stream smooth on large sessions instead of stalling per token.
    -- This is a THROTTLE: the timer starts on the first token of a batch.
    -- Only incomplete structural prefixes wait for classification; ordinary
    -- prose flushes every tick even under continuous token flow.
    local STREAM_FLUSH_MS = 30
    local pending = ""
    local flush_timer = nil
    local function flush_pending(final)
      if pending == "" then
        return
      end
      local data = pending
      pending = ""
      if not final then
        data, pending = document.split_stream_tail(buf, data)
      end
      if data == "" then
        return
      end
      sync_followers()
      document.append_text(buf, data)
      follow_tail()
    end
    local function on_flush_tick(timer)
      if flush_timer ~= timer then
        return
      end -- a final flush cancelled this tick
      flush_timer = nil
      timer:stop()
      timer:close()
      flush_pending()
    end
    -- uv timer callbacks run in a fast event context; schedule_wrap escapes
    -- it so nvim_buf_set_text is legal inside flush_pending.
    local on_flush_tick_wrapped = vim.schedule_wrap(on_flush_tick)
    local function finish_flush()
      if flush_timer then
        flush_timer:stop()
        flush_timer:close()
        flush_timer = nil
      end
      flush_pending(true)
    end
    stream_flush[buf] = finish_flush
    local function append(data)
      if data == "" then
        return
      end
      pending = pending .. data
      if not flush_timer then
        local timer = vim.uv.new_timer()
        flush_timer = timer
        timer:start(STREAM_FLUSH_MS, 0, function()
          on_flush_tick_wrapped(timer)
        end)
      end
    end
    local function route_event(ev)
      sync_followers()
      handle_event(buf, ev)
      follow_tail()
    end
    local function complete(result)
      status, barrier = nil, false
      finish_flush()
      sync_followers()
      running[buf] = nil
      follow_override[buf] = nil
      stderr_chunks = {}
      local compact = vim.b[buf].yap_compact_pending
      vim.b[buf].yap_compact_pending = nil
      audit.drain(buf) -- final bytes; a killed tool never sent tool_end
      audit.flush(buf) -- emit any unterminated final line
      for path in pairs(state.live_logs[buf] or {}) do
        vim.npcall(os.remove, path)
      end
      state.live_logs[buf] = nil
      live[buf] = nil
      spinner.stop_if_idle()
      audit.poll_stop_if_idle()
      repair_stream_tail(buf)
      if not result.ok then
        local err = result.error or table.concat(stderr_chunks, "\n"):gsub("%s+$", "")
        report_error(buf, err ~= "" and err or "backend exited")
        close_stream(buf)
        follow_tail()
        close_if_requested(buf)
        return
      end
      -- The binary can complete "successfully" with an embedded error
      -- marker (e.g. empty completion, max tool iterations): surface it.
      do
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for i = #lines, 1, -1 do
          local l = lines[i]
          if l:match("^# @%a+") then
            break
          end
          local err = l:match("^<!%-%- yap:error$") and lines[i + 1]
          if err then
            errors[buf] = err
            local parent = vim.b[buf].yap_subagent_parent
            if not (parent and running[parent]) then
              vim.notify("yap: " .. err, vim.log.levels.WARN)
            end
            break
          end
        end
      end
      -- A late steer was never injected: keep it as a draft, not an
      -- automatically sent follow-up turn.
      document.append_lines(buf, { "# @user", "" })
      leave_undelivered_steer(buf)
      follow_tail()
      awaiting[buf] = true
      require("harness.session").save(buf)
      if subagent_done[buf] then
        local done = subagent_done[buf]
        subagent_done[buf] = nil
        done(not errors[buf])
      end
      describe.refresh(buf, "answer")
      -- A completed turn is a first-class event (herdr's "working → blocked
      -- → idle" notification). Fire it once the buffer is in its final state
      -- so handlers see the appended `# @user` and the saved session.
      vim.api.nvim_exec_autocmds("User", {
        pattern = "YapTurnDone",
        modeline = false,
        data = { buf = buf, turn = last_turn[buf] },
      })
      if compact then
        M.compact_offer(buf)
      end
      -- close_session is a frontend side effect (like quickfix): the agent
      -- asked to end the session, so once the turn is fully done and the
      -- session file is saved, wipe the buffer. The BufWipeout autocmd in
      -- setup() tears down this buffer's serve backend.
      close_if_requested(buf)
    end
    local handle
    local ok, started = pcall(
      vim.system,
      { M.config.bin, "serve" },
      {
        stdin = true,
        text = true,
        stdout = vim.schedule_wrap(function(_, data)
          if not data or servers[buf] ~= handle then
            return
          end
          partial = partial .. data
          while partial ~= "" do
            if partial:sub(1, 1) == "\30" then
              local i = partial:find("\n", 1, true)
              if not i then
                break
              end
              local line = partial:sub(2, i - 1)
              partial = partial:sub(i + 1)
              local status_line = line:match("^yap:turn_end (.+)$")
              local parsed, result = pcall(vim.json.decode, status_line or "")
              if status_line and parsed and type(result) == "table" and type(result.ok) == "boolean" then
                status = result
                if running[buf] and barrier then
                  complete(result)
                end
              else
                append("?" .. line .. "\n")
              end
            else
              local i = partial:find("\30", 1, true)
              if i then
                append(partial:sub(1, i - 1))
                partial = partial:sub(i)
              else
                append(partial)
                partial = ""
              end
            end
          end
        end),
        stderr = vim.schedule_wrap(function(_, data)
          if not data or servers[buf] ~= handle then
            return
          end
          stderr_partial = stderr_partial .. data
          while true do
            local i = stderr_partial:find("\n", 1, true)
            if not i then
              break
            end
            local line = stderr_partial:sub(1, i - 1)
            stderr_partial = stderr_partial:sub(i + 1)
            local ev = line:match("^yap:event (.+)$")
            if ev then
              local parsed, event = pcall(vim.json.decode, ev)
              if parsed and event.type == "turn_complete" then
                barrier = true
                if running[buf] and status then
                  complete(status)
                end
              else
                route_event(ev)
              end
            else
              table.insert(stderr_chunks, line)
            end
          end
        end),
      },
      vim.schedule_wrap(function(result)
        if servers[buf] ~= handle then
          return
        end
        servers[buf] = nil
        pending_approvals[buf] = nil
        if partial ~= "" then
          append(partial)
          partial = ""
        end
        if stderr_partial ~= "" then
          table.insert(stderr_chunks, stderr_partial)
        end
        if running[buf] then
          complete({
            ok = false,
            error = table.concat(stderr_chunks, "\n"):gsub("%s+$", "") ~= "" and table.concat(stderr_chunks, "\n")
              or ("exit " .. result.code),
          })
        end
      end)
    )
    if not ok then
      spinner.stop_if_idle()
      audit.poll_stop_if_idle()
      stream_flush[buf] = nil
      report_error(buf, tostring(started))
      close_stream(buf)
      return false
    end
    handle = started
    servers[buf] = handle
    process = handle
  end

  running[buf] = process
  -- The frontmatter `tools` list is the per-session allowlist: hand-edit it
  -- (remove lines) to retract tools, effective on this send. A missing or
  -- empty list means unrestricted (all tools). `reasoning_level` is the
  -- same live-editable shape: read on every send so a hand-edited value
  -- takes effect without a :Yap rewrite.
  local tools = nil
  local reasoning_level = nil
  local fm_end = frontmatter.end_line(buf)
  if fm_end then
    local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, fm_end, false))
    if fm then
      if fm.tools and #fm.tools > 0 then
        tools = fm.tools
      end
      reasoning_level = fm.reasoning_level
    end
  end
  local payload = vim.json.encode({
    provider = provider,
    model = model,
    messages = messages,
    tools = tools,
    reasoning_level = reasoning_level,
    -- Request-only (like the context tail): the backend's own cwd is fixed
    -- when the buffer spawns it, so the live cwd is what keeps the tools'
    -- "default: the Neovim cwd" true after a :cd.
    cwd = vim.fn.getcwd(),
    -- The session's assets/ folder: transient tool files (live-tail logs,
    -- inline scripts, header files, SSH sockets) land here instead of /tmp.
    assets_dir = paths.assets_dir(buf),
  }) .. "\n"
  local ok, err = pcall(function()
    process:write(payload)
  end)
  if not ok then
    process:kill(15)
    return false
  end
  return true
end

-- Subagent child teardown lives in harness.subagent.
--- Kill the in-flight request for the current buffer.
function M.stop(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local child = subagent_children[buf]
  subagent_children[buf] = nil
  if child then
    M.stop(child)
  end
  local handle = running[buf]
  if handle then
    stopped[buf] = true
    handle:kill(15) -- the exit callback closes the interrupted turn
    servers[buf] = nil
    running[buf] = nil
    -- servers[buf] is already nil, so the process exit callback's
    -- `servers[buf] ~= handle` guard returns early and never reaches its own
    -- cleanup: release the per-turn UI state it would have released here.
    pending_approvals[buf] = nil
    spinner.stop_if_idle()
    audit.poll_stop_if_idle()
    audit.drain(buf)
    audit.flush(buf) -- emit any unterminated final line
    for path in pairs(state.live_logs[buf] or {}) do
      vim.npcall(os.remove, path)
    end
    state.live_logs[buf] = nil
    live[buf] = nil
    local f = stream_flush[buf]
    if f then
      f()
      stream_flush[buf] = nil
    end
    repair_stream_tail(buf)
    close_stream(buf)
  end
end

-- ─── Buffers ───────────────────────────────────────────────────────────────

-- Keymaps and buffer options shared by new and reopened session buffers.
function M.show_keymaps(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local entries, seen = {}, {}
  local modes = { "n", "i", "x", "o" }
  local function collect(maps, mode)
    for _, map in ipairs(maps) do
      if map.desc and map.desc:match("^yap:") then
        local key = mode .. "\0" .. map.lhs .. "\0" .. map.desc
        if not seen[key] then
          seen[key] = true
          entries[#entries + 1] = {
            lhs = map.lhs,
            mode = mode,
            desc = map.desc:sub(6),
          }
        end
      end
    end
  end
  for _, mode in ipairs(modes) do
    collect(vim.api.nvim_buf_get_keymap(buf, mode), mode)
    collect(vim.api.nvim_get_keymap(mode), mode)
  end
  table.sort(entries, function(a, b)
    if a.lhs == b.lhs then
      return a.mode < b.mode
    end
    return a.lhs < b.lhs
  end)

  local lines = {
    "Yap shortcuts (current buffer)",
    "Search with /, n and N; close with q or <Esc>.",
    "",
  }
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = string.format("%-18s %-2s %s", entry.lhs, entry.mode, entry.desc)
  end

  local panel = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(panel, 0, -1, false, lines)
  vim.bo[panel].modifiable = false
  vim.bo[panel].bufhidden = "wipe"
  local widest = 0
  for _, line in ipairs(lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line))
  end
  local width = math.max(1, math.min(vim.o.columns - 4, math.max(40, math.min(90, widest))))
  local height = math.max(1, math.min(#lines, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(panel, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Yap shortcuts ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = panel, silent = true, desc = "Close Yap shortcuts" })
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = panel, silent = true, desc = "Close Yap shortcuts" })
  return panel, win
end

local function setup_buffer(buf)
  -- Mark the buffer as a yap conversation BEFORE the filetype triggers the
  -- LSP's FileType autocommand, so the LspAttach guard in M.setup can see it.
  -- A session buffer is not code: markdown LSPs (semantic tokens, inlay hints)
  -- add per-redraw cost on a large session and buy nothing (R-buffer-only-state).
  vim.b[buf].yap = true
  state.sessions[buf] = true
  -- Opening a saved session (:edit) sets the filetype before setup_buffer
  -- runs, so a markdown client may already be attached; stop it.
  if vim.lsp and vim.lsp.get_clients then
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
      vim.npcall(client.stop, client)
    end
  end

  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide"
  -- Sessions are managed, not workspace files: unlisted so they never
  -- clutter :ls or buffer pickers (MiniPick.buffers etc.); reach them
  -- with the open-session picker.
  vim.bo[buf].buflisted = false

  -- Stop treesitter's syntax highlighter (not the parser) when the user
  -- opts out. touchup runs its own queries over the parser, which stays
  -- loaded either way. Deferred so the FileType autocommands that started
  -- the highlighter have run.
  if not M.config.syntax_highlight then
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local hl = vim.treesitter.highlighter and vim.treesitter.highlighter.active[buf]
      if hl and hl.destroy then
        hl:destroy()
      end
    end)
  end

  -- Diff hunks are meaningless on a session transcript, and mini.diff's
  -- number-column rendering collides with 'relativenumber': the two
  -- re-render the gutter together on every redraw (a ~20x cost on long
  -- sessions — relativenumber alone is ~0.01ms, mini.diff alone ~0, but
  -- combined ~0.24ms). Disable mini.diff here so relativenumber stays
  -- cheap. The buffer-local minidiff_disable flag makes mini.diff's
  -- BufEnter auto-enable refuse to re-attach.
  local ok_md, MiniDiff = pcall(require, "mini.diff")
  if ok_md and MiniDiff then
    vim.b[buf].minidiff_disable = true
    MiniDiff.disable(buf)
  end

  local keys = M.config.keymaps
  local map = function(mode, lhs, rhs, desc)
    if lhs == "" then
      return
    end
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  map("n", keys.send, M.send, "yap: send")
  map("i", keys.send, function()
    vim.cmd.stopinsert()
    M.send()
  end, "yap: send")
  map("n", keys.stop, function()
    M.stop()
  end, "yap: stop in-flight request")
  map("n", keys.change_model, function()
    M.change_model()
  end, "yap: change model")
  map("n", keys.live, function()
    M.live()
  end, "yap: live tool output")
  map("n", keys.scratch, function()
    M.scratch_toggle()
  end, "yap: toggle scratch")
  map("n", keys.insert, function()
    M.insert()
  end, "yap: insert template or skill")
  map("i", keys.insert, function()
    vim.cmd.stopinsert()
    M.insert()
  end, "yap: insert template or skill")
  map("i", keys.insert_file, function()
    M.insert_file({ from_insert = true })
  end, "yap: insert file reference")
  map("n", keys.insert_here, function()
    M.insert(nil, { at_cursor = true })
  end, "yap: insert template or skill at cursor")
  map("n", keys.help, function()
    M.show_keymaps(buf)
  end, "yap: show shortcuts")
  require("harness.fold").setup_buffer(buf, keys)
  require("harness.textobj").setup_buffer(buf, keys)

  -- Self-evaluating winbar: a pure function of buffer state, refreshed
  -- by Neovim on every redraw.
  vim.wo.winbar = "%!v:lua.require'harness'.winbar()"
end

--- Open a new yap session buffer.
function M.new(opts)
  opts = opts or {}
  local win = vim.api.nvim_get_current_win()
  local previous = vim.api.nvim_win_get_buf(win)
  -- `enew` (and the hidden case's closing nvim_win_set_buf) switches this
  -- window's buffer, which E1513 forbids while 'winfixbuf' is set — a
  -- mini.files explorer window pins its buffer. Clear it for the span of
  -- this function and restore it so a pinned window stays pinned.
  local fixed = vim.wo[win].winfixbuf
  vim.wo[win].winfixbuf = false
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  if opts.system then
    vim.b[buf].yap_system = opts.system
  end
  if opts.agent then
    vim.b[buf].yap_agent = opts.agent
  end
  if opts.tools then
    vim.b[buf].yap_tools = opts.tools
  end
  if opts.path then
    vim.b[buf].yap_path = opts.path
    vim.api.nvim_buf_set_name(buf, opts.path)
  end
  local provider, model = config.session_combo()
  vim.b[buf].yap_provider = opts.provider or provider
  vim.b[buf].yap_model = opts.model or model
  vim.b[buf].yap_project_cwd = vim.fs.normalize(vim.fn.getcwd())

  local lines = { "# @system", "" }
  vim.list_extend(lines, vim.split(vim.b[buf].yap_system or system_prompt(), "\n", { plain = true }))
  vim.list_extend(lines, { "", "# @user", "" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  frontmatter.sync(buf) -- prepend the session's model state (R-buffer-only-state: it lives in the buffer)
  -- Create the session file up front so the buffer is file-backed from
  -- the start: `:file` names the session immediately, before the first
  -- reply. The LSP guard in setup_buffer keeps markdown clients off it
  -- regardless of the .md extension.
  require("harness.session").save(buf)
  -- Create the session's live tool tail now (empty until a tool runs), before
  -- any :file rename or tool run.
  audit.ensure(buf)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })

  setup_buffer(buf)
  if opts.hidden then
    vim.api.nvim_win_set_buf(win, previous)
  end
  vim.wo[win].winfixbuf = fixed

  return buf
end

-- Subagent spawning and child teardown live in harness.subagent.

--- Open a saved session file as a yap buffer.
--- Turn a session-file buffer into a managed yap buffer: unlisted,
--- keymapped, live tool tail attached, model combo resumed from
--- frontmatter. Shared by :YapHistory resume and by directly opening
--- a file under ~/.config/yap/sessions/.
adopt = function(buf, path)
  if vim.b[buf].yap then
    return buf
  end
  vim.b[buf].yap_path = path
  vim.b[buf].yap_project_cwd = paths.project_cwd(path)
  -- Resume the recorded combo; legacy files without frontmatter keep the
  -- config default. Nothing is injected on open — that would dirty the
  -- buffer the moment it is resumed.
  local e = frontmatter.end_line(buf)
  if e then
    local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
    if fm and fm.provider and fm.provider ~= "" and fm.model and fm.model ~= "" then
      vim.b[buf].yap_provider = fm.provider
      vim.b[buf].yap_model = fm.model
    end
    if fm and fm.tools then
      vim.b[buf].yap_tools = fm.tools
    end
    if fm and fm.agent then
      vim.b[buf].yap_agent = fm.agent
    end
  end
  -- A reopened session that ended on `# @user` awaits the next reply;
  -- seed the overview hint so it counts before its first send here.
  winbar.seed_awaiting(buf)
  setup_buffer(buf)
  audit.ensure(buf) -- the live tool tail (empty until a tool runs)
  audit.seed_session_usage(buf) -- durable all-time totals from the audit log
  return buf
end
M.adopt = adopt

--- Switch the current window's buffer, briefly clearing `winfixbuf` so a
--- window fixed to its buffer can still be redirected (E1513).
local function switch_buf(buf)
  local win = vim.api.nvim_get_current_win()
  local fixed = vim.wo[win].winfixbuf
  vim.wo[win].winfixbuf = false
  vim.api.nvim_set_current_buf(buf)
  vim.wo[win].winfixbuf = fixed
end

--- Focus an already-loaded buffer: jump to an existing window, otherwise
--- show it in the current one (unlisted sessions have no other way back).
focus_buf = function(buf)
  local wins = vim.fn.win_findbuf(buf)
  if wins[1] then
    vim.api.nvim_set_current_win(wins[1])
  else
    switch_buf(buf)
  end
end

--- Load `path` into the current window, briefly clearing `winfixbuf` so a
--- window fixed to its buffer can still be redirected by `:edit` (E1513).
---
--- The read is forced to utf-8. A session file is UTF-8, but one stray byte
--- in it (a tool result that dumped binary) makes 'fileencodings' fall back to
--- latin1, and from then on every :write re-encodes the WHOLE transcript to
--- latin1 — one 0xBF per character outside latin1. Forcing the encoding on
--- read keeps writes utf-8 and repairs the stray byte to `?` instead.
local function edit_buf(path)
  local win = vim.api.nvim_get_current_win()
  local fixed = vim.wo[win].winfixbuf
  vim.wo[win].winfixbuf = false
  vim.cmd("edit ++enc=utf-8 " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  -- A lossy read (that stray byte became `?`) makes Vim mark the buffer
  -- 'readonly' to protect the file. Repairing it is the point here, and yap
  -- saves sessions with :write!, which would otherwise warn W10 on every save.
  -- A file that really is unwritable keeps its flag.
  if vim.bo[buf].readonly and vim.fn.filewritable(path) == 1 then
    vim.bo[buf].readonly = false
  end
  vim.wo[win].winfixbuf = fixed
end

--- Fork the in-memory transcript into an independent managed session. Keep
--- the source buffer (and any running process) attached to its original path.
--- bufload adopts the new file; switching buffers instead of :edit also works
--- when the source has unsaved edits (ordinary :edit would raise E37).
function M.fork(name)
  local source = vim.api.nvim_get_current_buf()
  if not vim.b[source].yap then
    return nil, ":YapFork only works in a yap session"
  end
  local path, err = require("harness.session").fork(source, name, running[source] ~= nil)
  if not path then
    return nil, err
  end
  if not running[source] then
    require("harness.session").save(source)
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  focus_buf(buf)
  adopt(buf, path)
  -- bufload may have adopted the fork while the source was still current;
  -- winbar is window/buffer-local, so set it on the now-visible fork too.
  vim.wo.winbar = "%!v:lua.require'harness'.winbar()"
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  return path
end

--- Open a saved session file as a yap buffer.
function M.open(path)
  local buf = vim.fn.bufnr(vim.fn.fnamemodify(path, ":p"))
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    -- The in-memory buffer is the source of truth: reuse it even when it is
    -- not flagged 'modified'. `:edit` would re-read the file from disk and
    -- discard text typed but not yet persisted — and 'modified' can be false
    -- while the buffer still holds such text (the flag does not capture every
    -- in-memory-vs-disk divergence a session can reach).
    focus_buf(buf)
    return adopt(buf, path)
  end
  edit_buf(path)
  return adopt(vim.api.nvim_get_current_buf(), path)
end

--- Change the provider/model combo for the current buffer.
--- With an argument: "provider/model". Without: pick from setup()'s
--- models list, or — when that isn't configured — from `yap models`,
--- which queries every provider in config.json (GET /models).
function M.change_model(combo)
  if not combo then
    config.pick(function(choice)
      M.change_model(choice)
    end)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local provider, model = config.parse_combo(combo)
  if not provider then
    vim.notify("yap: expected provider/model, got: " .. combo, vim.log.levels.ERROR)
    return
  end
  vim.b[buf].yap_provider = provider
  vim.b[buf].yap_model = model
  frontmatter.sync(buf) -- persist: combo + used-models history live in the buffer
  -- A running turn adopts the new combo at its next model boundary; an idle
  -- buffer just uses it on the next send. The backend keeps native tool
  -- history intact, so no stop-and-resend is needed.
  local proc = running[buf]
  if proc then
    local ok = pcall(function()
      proc:write(vim.json.encode({ type = "model", provider = provider, model = model }) .. "\n")
    end)
    if not ok then
      vim.notify("yap: could not switch model mid-turn (backend gone)", vim.log.levels.WARN)
    end
  end
end

--- Change the default provider/model for NEW buffers, persisted to
--- `$XDG_CACHE_HOME/yap/default`. Does not touch the current buffer.
--- With an argument: "provider/model". Without: pick from the same list
--- as :YapChangeModel.
function M.change_default_model(combo)
  if not combo then
    config.pick(function(choice)
      M.change_default_model(choice)
    end)
    return
  end
  if not config.parse_combo(combo) then
    vim.notify("yap: expected provider/model, got: " .. combo, vim.log.levels.ERROR)
    return
  end
  config.write_default_combo(combo)
  vim.notify("yap: default model for new sessions: " .. combo, vim.log.levels.INFO)
end

--- Session title for the picker: `title` when set, else `description`,
--- else the filename. Subagents and forks are indented under their parent
--- when it is open. The project cwd is rendered separately by |M.instances|.
live_session_label = function(buf, parent)
  local name = vim.api.nvim_buf_get_name(buf)
  local path = (name ~= "" and not name:match("^%a+://")) and name or (vim.b[buf].yap_path or name)
  local e = frontmatter.end_line(buf)
  local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false)) or nil
  local session = require("harness.session")
  local label = session.label(path, fm and fm.title, fm and fm.description)
  local role = fm and fm.agent or vim.b[buf].yap_agent
  if role then
    local task = session.task(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    local fallback = view.collapse(vim.b[buf].yap_subagent_task or "")
    label = session.agent_label(role, fm and fm.title, fm and fm.description, task, fallback, label)
  end
  if role and parent then
    return "↳ " .. label
  end
  if fm and fm.forked_from then
    return parent and "↳ fork · " .. label or "fork · " .. label .. " (parent not shown)"
  end
  if role and (fm and fm.subagent_parent or vim.b[buf].yap_subagent_parent) then
    return label .. " (parent not shown)"
  end
  return label
end
M.session_label = live_session_label

--- Find an open buffer for a saved session and return its live picker status.
local function saved_session_status(path)
  local normalized = vim.fs.normalize(path)
  -- An open history row has a state icon, even when idle; closed rows have
  -- no status column, so they sit flush against the picker's left edge.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buf].yap then
      local name = vim.b[buf].yap_path or vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fs.normalize(name) == normalized then
        return picker.status(buf)
      end
    end
  end
end

--- Pick a saved session and open it. scope: "cwd" (default) or "all".
function M.sessions(scope)
  require("harness.session").pick({ scope = scope, status = saved_session_status }, function(path)
    M.open(path)
  end)
end

--- Alias for the saved-session history picker.
function M.history(scope)
  M.sessions(scope)
end
--- Sort waiting sessions last; their dedicated <leader>w picker
--- makes them easy to reach without letting them crowd the general list.
local function session_rank(buf)
  local s = picker.state(buf)
  if s == "error" then
    return 1
  elseif s == "running" then
    return 2
  elseif s == "stopped" then
    return 3
  elseif s == "waiting" then
    return 5
  end
  return 4 -- idle and done
end

--- Every open yap session buffer, annotated with its live state and sorted with
--- waiting sessions last. The needs-you picker omits the current leaf session,
--- but keeps a current parent when it has open children to group beneath it.
--- An optional `state` narrows the list: a state name ("running", "error",
--- "waiting", "stopped" or "idle"), a set of them (a table keyed by state
--- name), or nil for all. The
--- "needs you" includes ordinary waiting/stopped parents, but only stopped
--- or errored children: a finished child need not be replied to. A current
--- parent remains visible while it has an open subagent. Audit views are
--- never here — use :YapLive / <leader>l.
local function has_open_child(parent)
  local child = subagent_children[parent]
  if child and vim.api.nvim_buf_is_valid(child) then
    return true
  end
  local path = vim.fs.normalize(vim.b[parent].yap_path or vim.api.nvim_buf_get_name(parent))
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= parent and vim.b[buf].yap then
      if vim.b[buf].yap_subagent_parent == parent then
        return true
      end
      local e = frontmatter.end_line(buf)
      local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false)) or nil
      if
        fm
        and (
          (fm.forked_from and vim.fs.normalize(fm.forked_from) == path)
          or (fm.subagent_parent and vim.fs.normalize(fm.subagent_parent) == path)
        )
      then
        return true
      end
    end
  end
  return false
end

function M.instances(state)
  -- Normalize `state` to a set keyed by state name, or nil for "all".
  local states = state
  if type(state) == "string" then
    states = { [state] = true }
  end
  -- The "needs you" picker is the waiting + stopped set.
  local needs_you = states ~= nil and states.waiting == true and states.stopped == true
  local items = {}
  local current = vim.api.nvim_get_current_buf()
  local open_paths = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].yap then
      open_paths[vim.fs.normalize(vim.b[b].yap_path or vim.api.nvim_buf_get_name(b))] = b
    end
  end
  local attention_child = {}
  if needs_you then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local parent = vim.b[b].yap_subagent_parent
      if parent and vim.b[b].yap and (stopped[b] or errors[b]) then
        attention_child[parent] = true
      end
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local subagent_parent = vim.b[b].yap_subagent_parent
    local e = vim.b[b].yap and frontmatter.end_line(b)
    local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(b, 0, e, false)) or nil
    subagent_parent = subagent_parent
      or (fm and fm.subagent_parent and open_paths[vim.fs.normalize(fm.subagent_parent)])
    local fork_parent = fm and fm.forked_from and open_paths[vim.fs.normalize(fm.forked_from)]
    local parent = subagent_parent or fork_parent
    local is_subagent = fm and fm.agent or vim.b[b].yap_agent
    local include_current = not needs_you or (b == current and has_open_child(b))
    local child_needs_you = is_subagent and (stopped[b] or errors[b])
    if
      (b ~= current or include_current)
      and vim.b[b].yap
      and (not needs_you or not is_subagent or child_needs_you)
      and (states == nil or states[picker.state(b)] or (needs_you and (child_needs_you or attention_child[b])))
    then
      items[#items + 1] = {
        buf = b,
        text = live_session_label(b, parent ~= nil),
        path = parent and "" or vim.b[b].yap_project_cwd,
        state = picker.state(b),
        approval = pending_approvals[b] ~= nil,
        model = vim.b[b].yap_model,
        child = is_subagent or (fm and fm.forked_from),
        group_parent = (parent and vim.api.nvim_buf_is_valid(parent)) and parent or b,
        parent = parent,
        forked_from = fm and fm.forked_from,
      }
    end
  end
  if #items == 0 then
    if needs_you then
      local message = "yap: no conversations need a reply"
      if vim.b[current].yap and states[picker.state(current)] then
        message = "yap: this conversation is already open and waiting for your reply"
      end
      vim.notify(message, vim.log.levels.INFO)
    else
      vim.notify("yap: no open conversations", vim.log.levels.INFO)
    end
    return
  end
  -- Sort roots by state; keep each child directly below its parent.
  local by_buf, children = {}, {}
  for _, item in ipairs(items) do
    by_buf[item.buf] = item
  end
  local roots = {}
  for _, item in ipairs(items) do
    if item.parent and by_buf[item.parent] then
      local siblings = children[item.parent] or {}
      siblings[#siblings + 1] = item
      children[item.parent] = siblings
    else
      if item.parent then
        item.path = vim.b[item.buf].yap_project_cwd
        item.text = item.text:sub(#"↳ " + 1) .. " (parent not shown)"
      end
      roots[#roots + 1] = item
    end
  end
  table.sort(roots, function(a, b)
    local ra, rb = session_rank(a.buf), session_rank(b.buf)
    if ra ~= rb then
      return ra < rb
    end
    return a.text < b.text
  end)
  local ordered = {}
  local function add(item, depth)
    item.depth = depth
    ordered[#ordered + 1] = item
    local siblings = children[item.buf] or {}
    table.sort(siblings, function(a, b)
      return a.text < b.text
    end)
    for _, child in ipairs(siblings) do
      add(child, depth + 1)
    end
  end
  for _, item in ipairs(roots) do
    add(item, 0)
  end
  items = ordered
  -- Keep icons in a fixed column; indent titles, not the status column.
  -- Disambiguate roots by project only when this picker spans projects.
  local projects = {}
  for _, item in ipairs(items) do
    projects[vim.b[item.buf].yap_project_cwd or ""] = true
  end
  local multiple_projects = vim.tbl_count(projects) > 1
  local glyph = picker.glyphs()
  local icon_width = picker.icon_width(glyph)
  vim.ui.select(items, {
    prompt = needs_you and "yap waiting" or "yap sessions",
    format_item = function(item)
      local suffix = multiple_projects and item.path and item.path ~= "" and (" (" .. item.path .. ")") or ""
      local icon = (item.approval and glyph.approval) or glyph[item.state]
      return picker.prefix(icon, icon_width)
        .. string.rep("  ", item.depth)
        .. item.text
        .. suffix
    end,
    preview_item = function(item)
      if not vim.api.nvim_buf_is_valid(item.buf) then
        return nil -- a session can close while the picker is open
      end
      return require("harness.session").preview(vim.api.nvim_buf_get_lines(item.buf, 0, -1, false))
    end,
  }, function(choice)
    if choice and vim.api.nvim_buf_is_valid(choice.buf) and vim.api.nvim_buf_is_loaded(choice.buf) then
      focus_buf(choice.buf)
    end
  end)
end

--- Just the sessions needing a reply — waiting for one or manually stopped —
--- the "needs you" set (<leader>w).
function M.waiting()
  M.instances({ waiting = true, stopped = true })
end

function M.setup(opts)
  opts = opts or {}
  if opts.nerd_font == false then
    M.config.icons = vim.tbl_extend("force", M.config.icons, {
      since = "",
      total = "",
      running = "▶",
      stopped = "⏹",
      error = "✗",
      waiting = "◉",
      idle = "○",
      done = "✓",
      steer = "⌁",
      approval = "⚠", -- plain-Unicode backup for the shield_alert glyph
      cap_l = "[",
      cap_r = "]",
    })
  end
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  config.default_combo = config.read_default_combo()
  if not M.config.models or #M.config.models == 0 then
    config.load_models_cache()
    config.refresh_models()
  end
  -- Resolve every data path — defaults included — against the real home
  -- directory (R-data-paths): a relative or unset $HOME must never make yap
  -- read or write inside the project. `~` expands; a relative override is
  -- refused by paths.expand rather than silently resolved against the cwd.
  for _, key in ipairs({ "agents_file", "templates_dir", "skills_dir", "agents_dir", "sessions_dir" }) do
    local v = M.config[key]
    if type(v) == "string" and v ~= "" then
      M.config[key] = paths.expand(v)
    end
  end
  -- Propagate the (possibly overridden) data root to the path resolver.
  paths.dirs.sessions_dir = M.config.sessions_dir

  -- <leader>r, <leader>w, <leader>y, <leader>R and <leader>M are global:
  -- they list sessions across every buffer or change the default model, so
  -- they must work from any file, not just inside a session. The other
  -- keymaps act on the current buffer and stay buffer-local in setup_buffer.
  if M.config.keymaps.sessions ~= "" then
    vim.keymap.set("n", M.config.keymaps.sessions, function()
      M.instances()
    end, { silent = true, desc = "yap: sessions" })
  end
  if M.config.keymaps.waiting ~= "" then
    vim.keymap.set("n", M.config.keymaps.waiting, function()
      M.waiting()
    end, { silent = true, desc = "yap: waiting sessions" })
  end
  if M.config.keymaps.history ~= "" then
    vim.keymap.set("n", M.config.keymaps.history, function()
      M.sessions()
    end, { silent = true, desc = "yap: history" })
  end
  if M.config.keymaps.guard ~= "" then
    vim.keymap.set("n", M.config.keymaps.guard, function()
      guard.toggle()
    end, { silent = true, desc = "yap: guard board" })
  end
  if M.config.keymaps.change_default_model ~= "" then
    vim.keymap.set("n", M.config.keymaps.change_default_model, function()
      M.change_default_model()
    end, { silent = true, desc = "yap: change default model" })
  end

  -- Opening a file under ~/.config/yap/sessions/ directly (e.g. from a file
  -- explorer) adopts it as a managed yap session. Session buffers stay
  -- out of :ls no matter how they got in: BufAdd fires whenever a buffer
  -- enters the buffer list (new buffers, :badd, :args/:next, and plugins
  -- that relist), so unlisting there is the single consistent guard. It
  -- does not fire during startup, so the BufReadPost adopt below and the
  -- lazy-setup scan after it own that path.
  local adopt_group = vim.api.nvim_create_augroup("YapAdopt", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = adopt_group,
    callback = function(args)
      local process = servers[args.buf]
      if process then
        process:kill(15)
      end
      servers[args.buf] = nil
      running[args.buf] = nil
      pending_approvals[args.buf] = nil
      stream_flush[args.buf] = nil
      follow_override[args.buf] = nil
      -- Release the per-buffer UI state so the winbar's rollup and cache
      -- don't iterate/retain entries for buffers that are gone.
      live[args.buf] = nil
      state.live_usage[args.buf] = nil
      state.sessions[args.buf] = nil
      errors[args.buf] = nil
      last_turn[args.buf] = nil
      awaiting[args.buf] = nil
      stopped[args.buf] = nil
      describe.forget(args.buf)
      winbar.clear_desc(args.buf)
      fold.clear_text(args.buf)
      focus_forget(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = adopt_group,
    callback = function(args)
      local buf = args.buf
      if not vim.b[buf].yap then
        return
      end
      -- Capture the drawer buffers now: :bd unloads the session before the
      -- deferred check below runs, clearing vim.b[buf].yap_scratch. The audit
      -- view already survives via the module table, but capture it too.
      local scratch = vim.b[buf].yap_scratch
      local t = audit.view(buf)
      local audit_buf = t and t.bufnr
      -- Let window/buffer transitions settle; focusing a drawer alone must
      -- not close it while the session remains displayed in another window.
      vim.schedule(function()
        if #vim.fn.win_findbuf(buf) == 0 then
          close_session_drawers(buf, scratch, audit_buf)
        end
      end)
    end,
  })
  -- Persist a session as soon as it leaves every window, so the file on disk
  -- never trails the in-memory buffer. Neovim reloads an unmodified,
  -- file-backed buffer from disk when it is re-entered; if that file is
  -- stale (text typed but not yet saved), the reload silently drops the
  -- in-memory text. Saving on hide keeps the file current, so any
  -- reload/`:edit`/reopen is lossless. Only session buffers are saved —
  -- the live tool tail and scratch queue have no yap_path.
  vim.api.nvim_create_autocmd("BufHidden", {
    group = adopt_group,
    callback = function(args)
      local buf = args.buf
      if vim.b[buf].yap and vim.b[buf].yap_path then
        require("harness.session").save(buf)
      end
    end,
  })
  -- A session's in-memory buffer is the source of truth: the file is only a
  -- serialization and can trail the buffer (or be written by another
  -- instance). When Neovim detects the file changed outside the buffer, keep
  -- the buffer and suppress the "file has changed" prompt/reload — the next
  -- save re-serializes whatever is in memory.
  vim.api.nvim_create_autocmd("FileChangedShell", {
    group = adopt_group,
    callback = function(args)
      local buf = args.buf
      if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].yap then
        vim.v.fcs_choice = ""
      end
    end,
  })
  -- Record focus order so closing a session can land on a waiting session,
  -- then a running session, else the last file buffer (unlisted sessions are
  -- invisible to Neovim's own replacement-buffer search).
  vim.api.nvim_create_autocmd("BufEnter", {
    group = adopt_group,
    callback = function(args)
      focus_touch(args.buf)
    end,
  })
  -- harness.fold owns synchronous window-entry reconciliation; scheduling
  -- it here would expose an unfolded frame when a hidden stream is shown.
  -- Redirect :bd/:bw/:bdelete/:bunload of the current session buffer. The
  -- deletion itself fires BufUnload while curbuf is still the session; by
  -- the time a scheduled callback runs, Neovim has moved curbuf to another
  -- listed buffer or to the fresh empty buffer its "last listed buffer"
  -- path creates. Switch to the fallback and drop that empty buffer.
  vim.api.nvim_create_autocmd("BufUnload", {
    group = adopt_group,
    callback = function(args)
      local buf = args.buf
      if vim.b[buf].yap then
        subagent.close_children(buf)
        M.stop(buf)
      end
      if vim.api.nvim_get_current_buf() ~= buf or not vim.b[buf].yap then
        return
      end
      -- A blocking command-line prompt (vim.ui.select's inputlist/input)
      -- keeps the session as the current buffer while the user is really in
      -- the picker; close quietly like a background turn instead of
      -- redirecting the user to another session mid-pick.
      if vim.fn.getcmdtype() ~= "" then
        return
      end
      local target = focus_fallback(buf)
      vim.schedule(function()
        -- `:edit!` (and any reload) unloads then reloads the same buffer, so
        -- it is loaded again by the time this runs: that is a reload, not a
        -- close. Leave the session in place instead of redirecting it away.
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
          return
        end
        local win = vim.api.nvim_get_current_win()
        local cur = vim.api.nvim_get_current_buf()
        if not target or not vim.api.nvim_buf_is_valid(target) then
          -- Every fallback is already visible in another split (or there is
          -- nothing left to land on): collapse this now-empty window instead
          -- of duplicating the session already on screen.
          if vim.api.nvim_buf_get_name(cur) == "" and not vim.bo[cur].modified then
            local lines = vim.api.nvim_buf_get_lines(cur, 0, -1, false)
            if #lines <= 1 and (#lines == 0 or lines[1] == "") then
              local tab = vim.api.nvim_get_current_tabpage()
              local normal = 0
              for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
                if vim.api.nvim_win_get_config(w).relative == "" then
                  normal = normal + 1
                end
              end
              if normal > 1 then
                vim.api.nvim_win_close(win, true)
                if not vim.api.nvim_win_is_valid(win) then
                  vim.npcall(vim.api.nvim_buf_delete, cur, { force = true })
                end
              end
            end
          end
          return
        end
        if cur == target then
          return
        end
        -- Drop the empty buffer :bd just created so no stray [No Name]
        -- lingers in :ls.
        if vim.api.nvim_buf_get_name(cur) == "" and not vim.bo[cur].modified then
          local lines = vim.api.nvim_buf_get_lines(cur, 0, -1, false)
          if #lines <= 1 and (#lines == 0 or lines[1] == "") then
            switch_buf(target)
            vim.npcall(vim.api.nvim_buf_delete, cur, { force = true })
            return
          end
        end
        switch_buf(target)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = adopt_group,
    callback = function()
      for _, process in pairs(servers) do
        process:kill(15)
      end
    end,
  })
  local function is_session_path(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    local root = paths.sessions_root()
    -- Only the session Markdown itself is a session: the sidecar files in
    -- the same directory (notes.md and audit.jsonl) must never be adopted,
    -- or the scratch jotter becomes a session (its own winbar, its own
    -- <C-s> send, a rollup entry) instead of dispatching to its owner. The
    -- session file is always named `session.md`; a `.md` suffix alone no
    -- longer marks a session (notes.md is also `.md`).
    return name, name:sub(1, #root + 1) == root .. "/" and vim.fn.fnamemodify(name, ":t") == "session.md"
  end
  vim.api.nvim_create_autocmd("BufAdd", {
    group = adopt_group,
    callback = function(args)
      local _, session_path = is_session_path(args.buf)
      if session_path then
        vim.bo[args.buf].buflisted = false
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = adopt_group,
    callback = function(args)
      local name, session_path = is_session_path(args.buf)
      if session_path then
        adopt(args.buf, name)
      end
    end,
  })
  -- The session's identity is its directory, so a `:file`/`:saveas` rename no
  -- longer renames or copies a session; renaming the directory does, and
  -- |:YapFork| copies. save() re-points the buffer at its canonical
  -- <dir>/session.md, so a stray buffer name is never followed or written to.
  -- The winbar degrades with window width (see render_winbar); re-evaluate
  -- its `%!` expression whenever a window is resized.
  vim.api.nvim_create_autocmd("WinResized", {
    group = adopt_group,
    callback = function()
      vim.cmd.redrawstatus()
    end,
  })
  -- Session files loaded before setup() ran (lazy loading) missed both
  -- BufAdd and BufReadPost; unlist them once, when setup() finally runs.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local _, session_path = is_session_path(b)
    if session_path then
      vim.bo[b].buflisted = false
    end
  end

  -- yap buffers carry no language server: the buffer is the conversation
  -- (R-buffer-only-state), and a markdown LSP streaming semantic-token/inlay-hint updates is
  -- pure per-redraw cost. The guard stops any client that attaches to a
  -- marked buffer; setup_buffer marks the buffer and stops clients that
  -- attached during :edit before the mark existed.
  local group = vim.api.nvim_create_augroup("YapLsp", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      if vim.b[args.buf].yap and args.data and args.data.client_id then
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client then
          vim.npcall(client.stop, client)
        end
      end
    end,
  })

  -- Turn completion is a first-class event: User YapTurnDone fires per
  -- buffer when a send finishes. The default handler is the herdr-style
  -- "it's waiting for you" toast, but any user autocmd can hook the
  -- same event — noice/nf-notify rendering, chaining a next send, etc.
  -- Announce a completed conversation only when it is not visible in any
  -- window. A delegated child reports to its running parent instead.
  local notify_group = vim.api.nvim_create_augroup("YapTurn", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = notify_group,
    pattern = "YapTurnDone",
    callback = function(args)
      local data = args.data or {}
      if not M.config.notify_done then
        return
      end
      -- The error path already notified (R-error-surface); don't double up.
      local parent = vim.b[data.buf].yap_subagent_parent
      if errors[data.buf] or (parent and running[parent]) then
        return
      end
      -- The session is being closed by a tool call, so there is no waiting
      -- session to announce when this turn finishes.
      if close_after_turn[data.buf] then
        return
      end
      -- No toast if the user can already see the stream in another window.
      if vim.fn.win_findbuf(data.buf)[1] then
        return
      end
      local title = live_session_label(data.buf)
      local msg = ("yap: %s %s"):format(title, M.config.icons.waiting)
      vim.notify(msg, vim.log.levels.INFO, { title = "yap" })
    end,
  })
end

return M
