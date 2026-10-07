-- yap.nvim — the buffer is the conversation.
--
-- A yap buffer is plain markdown. Headings of the form `# @user`,
-- `# @assistant` and `# @system` delimit messages; everything between
-- headings is message content. The buffer is the ONLY state: deleting a
-- block removes it from the conversation, editing an assistant reply
-- changes what the model "said", inserting a fake reply steers it.
-- gptel semantics, Neovim native.
--
-- Sending serializes the whole buffer to the `yap` binary, which talks
-- to the provider and streams the reply back into the buffer.

local M = {}

local paths = require("harness.path")
local config = require("harness.config")

M.config = config.defaults

local state = require("harness.state")
local util = require("harness.util")
local frontmatter = require("harness.frontmatter")
local winbar = require("harness.winbar")
local spinner = require("harness.spinner")
local drawer = require("harness.drawer")
local scratchmod = require("harness.scratch")

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

local start_subagent
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
-- non-session (file) buffer. Idle sessions are not a landing spot.
local function focus_fallback(buf)
  local function open(b)
    return b ~= buf and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b)
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
    if open(b) and not vim.b[b].yap then
      return b
    end
  end
  return nil
end

-- The harness's own boilerplate, always injected as the first system
-- message on every send. It is independent of agents_file (the user's
-- rules) and lives here so session files never store it.
local function yap_about()
  return [[# About Yap

You are running inside Yap, an agent harness for Neovim. The conversation is an editable Markdown buffer and the source of truth: `# @system`, `# @user`, and `# @assistant` headings delimit messages; editing or deleting a message branches or rewrites history, and the visible transcript is what is re-sent. Never emit one of those headings or a `<!-- yap:` marker line in a reply; indent or fence it instead.

Between turns, tool calls and their results are plain text in the transcript, not re-executed or re-sent. When asked about Yap itself, read `README.md` / `doc/yap.txt` in the project (normally `/opt/code/yap`) rather than guessing.

For GitHub searches and reading GitHub code, repositories, issues, pull requests, files, or Projects, use the `github` tool rather than curl, fetch, websearch, bash, or `gh`. Use other tools only if the `github` tool cannot perform the needed operation; never pass the GitHub token in tool arguments.

## Skills

Skills are reusable on-demand instructions in Markdown files under ]] .. M.config.skills_dir .. [[ (`<name>.md`). The `## Skills` list in the system block names them. Before working in a listed domain, `read` the matching skill file and follow it; read only what you need.

## Subagents

- `subagent` takes a `role` (from `roles_dir`, default `~/.yap/roles/<role>.md`) and a self-contained `task`. It blocks until the child finishes and returns the child's answer and session path; inspect the child session for its full conversation. To ask a follow-up, pass `session` with that path and `task` with the question (omit `role`); this appends a user turn to the same child, preserving its system prompt and history. A bare model name inherits the parent's provider/model.
]]
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

--- Find the yap:usage marker the binary appended for this turn, fold its
--- numbers into the buffer's session totals (winbar), and remove the marker.
local function consume_usage(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = #lines, 1, -1 do
    local json = lines[i]:match("^<!%-%- yap:usage (.+) %-%->$")
    if json then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, {})
      local ok, data = pcall(vim.json.decode, json)
      if ok and type(data) == "table" then
        local u = vim.b[buf].yap_usage or { prompt = 0, completion = 0 }
        u.prompt = u.prompt + (data.prompt or 0)
        u.completion = u.completion + (data.completion or 0)
        if data.cost then
          u.cost = (u.cost or 0) + data.cost
        end
        vim.b[buf].yap_usage = u
      end
      return
    end
  end
end

function M.parse_buffer(buf)
  return document.parse_buffer(buf)
end
function M.insert(name, opts)
  return require("harness.template").insert(name, opts)
end
function M.template_names()
  return require("harness.template").template_names()
end

local function file_items(cwd)
  local items = {}
  local function scan(dir, prefix)
    for name, kind in vim.fs.dir(dir) do
      if name ~= ".git" then
        local path = vim.fs.joinpath(dir, name)
        local relative = prefix == "" and name or (prefix .. "/" .. name)
        if kind == "directory" then
          scan(path, relative)
        elseif kind == "file" then
          items[#items + 1] = relative
        end
      end
    end
  end
  scan(cwd, "")
  table.sort(items)
  return items
end

--- Pick a file under the current :pwd and insert an @path reference at the cursor.
function M.insert_file()
  local buf = vim.api.nvim_get_current_buf()
  if not (vim.b[buf].yap or vim.b[buf].yap_owner) then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local cwd = vim.fn.getcwd()

  local function insert(path)
    if not path or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local relative = vim.fs.relpath(cwd, path) or path
    relative = relative:gsub("\\\\", "/")
    local reference = relative:find("%s") and ('@"' .. relative .. '"') or ("@" .. relative)
    local text = reference .. " "
    vim.api.nvim_buf_set_text(buf, cursor[1] - 1, cursor[2], cursor[1] - 1, cursor[2], { text })
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_set_cursor(win, { cursor[1], cursor[2] })
    end
  end

  if _G.MiniPick and MiniPick.builtin and MiniPick.builtin.files then
    MiniPick.builtin.files(nil, {
      source = { cwd = cwd, choose = insert },
    })
    return
  end

  local function open_picker(items)
    if #items == 0 then
      vim.notify("yap: no files to insert under " .. cwd, vim.log.levels.INFO)
      return
    end
    vim.ui.select(items, { prompt = "yap file" }, insert)
  end

  if vim.fn.executable("rg") == 1 then
    vim.system({ "rg", "--files", "--hidden", "-g", "!.git" }, { cwd = cwd, text = true }, function(result)
      vim.schedule(function()
        local items = result.code == 0 and vim.split(result.stdout or "", "\n", { trimempty = true }) or {}
        open_picker(items)
      end)
    end)
  else
    open_picker(file_items(cwd))
  end
end

function M.is_running(buf)
  return state.is_running(buf)
end

-- ─── Send ──────────────────────────────────────────────────────────────────

-- One persistent serve backend per chat buffer, so several sessions can
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

-- Per-chat-buffer persistent audit view: every audit event is rendered
-- into ONE unlisted buffer, yap://<session>-audit, opened by :YapLive.
-- The audit view is not a second log — it is the live, human-readable
-- rendering of the JSON Lines audit log (see audit_path), rebuilt from
-- it on reopen. Only the audit log is persisted.
local follow_override = {} -- chat buf -> windows deliberately focused by YapAlerts during a turn
local audits = {} -- chat buf → { bufnr, offset, has_content, audit }

-- The audit dir holds one JSON Lines audit log per session, keyed by
-- the session's basename, so the sessions dir stays clean.

--- Append one event as a JSON object to the session's audit log.
local function audit_append(buf, ev)
  local t = audits[buf]
  if not t then
    return
  end
  if not t.audit then
    t.audit = paths.audit_path(buf)
    -- 0700: the audit log holds full tool args and results (potentially
    -- secrets); the directory must not be world-readable.
    vim.fs.mkdir(vim.fn.fnamemodify(t.audit, ":h"), { parents = true, mode = 448 }) -- 0o700
  end
  vim.fn.writefile({ vim.json.encode(ev) }, t.audit, "a")
end

--- Point the audit log at the session file's name; a `:file` rename
--- (which also renames the session) renames the log to match.
local function audit_follow(buf)
  local t = audits[buf]
  if not t or not t.audit or not vim.b[buf].yap_path then
    return
  end
  local want = paths.audit_path(buf)
  if want ~= t.audit and vim.fn.filereadable(want) == 0 then
    vim.fs.mkdir(vim.fn.fnamemodify(want, ":h"), { parents = true, mode = 448 }) -- 0o700
    if os.rename(t.audit, want) then
      t.audit = want
    end
  end
end

--- Seed the all-time session usage from the audit log: sum every turn_end
--- journal entry so a reopened session shows its full historical cost
--- immediately. yap_usage is per-buffer and resets on reopen; this is its
--- durable per-session counterpart (the audit log, not the session file,
--- is the source of truth).
local function seed_session_usage(buf)
  local su = { prompt = 0, completion = 0 }
  local path = paths.audit_path(buf)
  if vim.fn.filereadable(path) == 1 then
    for _, line in ipairs(vim.fn.readfile(path)) do
      if line ~= "" then
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" and ev.type == "turn_end" then
          su.prompt = su.prompt + (ev.prompt or 0)
          su.completion = su.completion + (ev.completion or 0)
          if ev.cost then
            su.cost = (su.cost or 0) + ev.cost
          end
        end
      end
    end
  end
  vim.b[buf].yap_session_usage = su
end

local function ensure_audit(buf)
  local t = audits[buf]
  if t and vim.api.nvim_buf_is_valid(t.bufnr) then
    return t
  end
  local name = paths.audit_buf_name(buf)
  local tbuf = util.find_or_create_buffer(name, false, true) -- unlisted scratch: never in :ls or buffer pickers
  vim.bo[tbuf].bufhidden = "hide"
  vim.bo[tbuf].modifiable = false

  t = { bufnr = tbuf, offset = 0, has_content = false }
  audits[buf] = t

  -- Replay the audit log so the live view survives restarts.
  local events = {}
  local path = paths.audit_path(buf)
  if vim.fn.filereadable(path) == 1 then
    for _, line in ipairs(vim.fn.readfile(path)) do
      if line ~= "" then
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" then
          events[#events + 1] = ev
        end
      end
    end
  end
  vim.bo[tbuf].modifiable = true
  t.has_content, t.reviews = audit.rebuild(tbuf, events)
  vim.bo[tbuf].modifiable = false
  return t
end

--- Append an event to the audit log and render it into the audit view.
local function append_event(buf, ev)
  local t = ensure_audit(buf)
  audit_append(buf, ev)
  vim.bo[t.bufnr].modifiable = true
  audit.append(t, ev)
  vim.bo[t.bufnr].modifiable = false
  audit.scroll(t.bufnr)
end

--- Cap the raw tool output streamed into the live audit view (and audit
--- log) per tool run. The returned tool result is already tail-truncated
--- to 50KB; the live audit view must not accumulate the full log — a
--- runaway command writing gigabytes would otherwise balloon the audit
--- view buffer (and audit log) and OOM the editor. 256KB is ample for
--- watching progress while keeping memory bounded.
local LIVE_OUTPUT_CAP = 256 * 1024

--- Append newly written bytes of the running tool's log to the audit
--- view buffer (called on the spinner tick, on tool_end, and on process
--- exit). Defined via the forward declaration: the spinner ticks
--- before this section runs.
local function drain_audit(buf)
  local t, l = audits[buf], live[buf]
  if not t or not l then
    return
  end
  local fd = vim.uv.fs_open(l.log, "r", 438)
  if not fd then
    return
  end
  local stat = vim.uv.fs_fstat(fd)
  if not stat then
    vim.uv.fs_close(fd)
    return
  end
  local data
  local room = LIVE_OUTPUT_CAP - (l.out or 0)
  if stat.size > t.offset and room > 0 then
    local want = math.min(stat.size - t.offset, room)
    data = vim.uv.fs_read(fd, want, t.offset)
    if data then
      l.out = (l.out or 0) + #data
    end
  end
  t.offset = stat.size -- always advance past the read (or skipped) bytes
  vim.uv.fs_close(fd)
  if data and #data > 0 then
    append_event(buf, { type = "output", name = l.name, ts = os.date("%Y-%m-%dT%H:%M:%S"), data = data })
  elseif room <= 0 and stat.size > 0 and not l.truncated then
    l.truncated = true
    append_event(buf, {
      type = "output",
      name = l.name,
      ts = os.date("%Y-%m-%dT%H:%M:%S"),
      data = ("[live output truncated at %d bytes; remaining %d bytes not shown]\n"):format(
        LIVE_OUTPUT_CAP,
        stat.size - LIVE_OUTPUT_CAP
      ),
    })
  end
end

-- Poll tool logs independently of the visual spinner. Direct drains on
-- tool_end and process exit still capture the final bytes before cleanup.
local audit_poll_timer
local function audit_poll_stop_if_idle()
  if audit_poll_timer and not next(running) then
    audit_poll_timer:stop()
    audit_poll_timer:close()
    audit_poll_timer = nil
  end
end
local function audit_poll_start()
  if audit_poll_timer then
    return
  end
  audit_poll_timer = vim.uv.new_timer()
  audit_poll_timer:start(
    0,
    180,
    vim.schedule_wrap(function()
      for b in pairs(running) do
        drain_audit(b)
      end
      audit_poll_stop_if_idle()
    end)
  )
end

--- Handle one `yap:event {json}` line from the binary's stderr.
local live_session_label
local inspect_approval

local function answer_approval(buf, approved)
  local ev = pending_approvals[buf]
  if not ev then
    return
  end
  pending_approvals[buf] = nil
  local process = servers[buf]
  if not process then
    return
  end -- backend stopped or timed out; never approve a stale call
  process:write(vim.json.encode({ type = "approval_result", id = ev.id, approved = approved }) .. "\n")
  append_event(buf, { type = "approval_result", id = ev.id, approved = approved, ts = os.date("%Y-%m-%dT%H:%M:%S") })
end

local function handle_event(buf, json_line)
  local ok, ev = pcall(vim.json.decode, json_line)
  if not ok or type(ev) ~= "table" then
    return
  end
  ev.ts = os.date("%Y-%m-%dT%H:%M:%S")
  if ev.type == "tool_start" and ev.log then
    live[buf] = { name = ev.name or "tool", log = ev.log, since = os.time(), out = 0 }
    local t = ensure_audit(buf)
    t.offset = 0
    append_event(buf, ev)
  elseif ev.type == "tool_end" then
    drain_audit(buf) -- the log is complete; capture the final bytes
    live[buf] = nil
    -- Go keeps the log for us; once drained, an untruncated one is gone
    -- (a truncated log stays: its result references it).
    if ev.log and not ev.truncated then
      vim.npcall(os.remove, ev.log)
    end
  elseif ev.type == "subagent_request" then
    start_subagent(buf, ev)
  elseif ev.type == "subagent_timeout" then
    local child = subagent_children[buf]
    if child then
      M.stop(child)
    end
  elseif ev.type == "approval_request" then
    append_event(buf, ev)
    local command = ev.command or ""
    local ok_args, args = pcall(vim.json.decode, command)
    -- Show every argument, not a truncated 300-character prefix: approval
    -- must not hide the operation being authorized. SSH sends plain text.
    local detail = ok_args and vim.inspect(args) or command
    pending_approvals[buf] = ev
    local choice = vim.fn.confirm(
      ("yap: approve %s in %s?\nReason: %s\n\n%s\n\nInspect shows the call in its conversation and audit; use :YapApproval to return (5 minute timeout)."):format(
        ev.tool or "tool",
        live_session_label(buf),
        ev.reason or "review call",
        detail
      ),
      "&Run\n&Deny\n&Inspect",
      2,
      "Warning"
    )
    if choice == 3 then
      inspect_approval(buf, ev)
      vim.notify("yap: call paused; :YapApproval to Run, Deny or Inspect again (5 minute timeout)", vim.log.levels.WARN)
    else
      answer_approval(buf, choice == 1)
    end
  elseif ev.type == "approval_timeout" then
    pending_approvals[buf] = nil
    append_event(buf, ev)
  elseif ev.type == "alert_advice" then
    -- Record before notifying: the picker can now navigate to this exact alert.
    append_event(buf, ev)
    vim.notify(
      ("yap: %s (%s) — %s %s (P=%.2f, severity=%.2f)\n:YapAlerts"):format(
        live_session_label(buf),
        vim.fn.fnamemodify(vim.b[buf].yap_path or vim.api.nvim_buf_get_name(buf), ":t"),
        ev.name or "tool",
        ev.reason or "flagged",
        tonumber(ev.p_alert) or 0,
        tonumber(ev.severity) or 0
      ),
      vim.log.levels.WARN,
      { title = "yap alert" }
    )
  elseif ev.type == "tool_call" then
    -- quickfix is a frontend side effect: only a live tool_call event
    -- creates a list, so persisted tool blocks never replay on reopen.
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
    append_event(buf, ev) -- full arguments for every tool (bash renders via tool_start)
  elseif ev.type == "tool_result" then
    append_event(buf, ev) -- full result; bash output already streamed above
  elseif ev.type == "retry" then
    append_event(buf, ev) -- a transient generation error was retried
  elseif ev.type == "steer" then
    if steer[buf] == ev.text then
      steer[buf] = nil -- delivered: remove only the matching live draft
      local scratch = vim.b[buf].yap_scratch
      if scratch and vim.api.nvim_buf_is_valid(scratch) and scratchmod.section_text(scratch, "steer") == ev.text then
        scratchmod.set_section(scratch, "steer", {})
        scratchmod.save(scratch)
      end
    end
    append_event(buf, ev) -- audit trail: a steering message landed mid-turn
  elseif ev.type == "model_change" then
    append_event(buf, ev) -- audit trail: a model switch landed mid-turn
  elseif ev.type == "tool_text_warning" then
    append_event(buf, ev) -- the model emitted a tool call as text; nothing ran
  elseif ev.type == "usage" then
    state.live_usage[buf] = ev
    vim.cmd.redrawstatus()
  elseif ev.type == "turn_end" then
    state.live_usage[buf] = nil
    last_turn[buf] = ev -- for the User YapTurnDone event on exit
    -- Fold this turn into the session's all-time totals (seeded from the
    -- audit log on open; this keeps the in-memory copy in step with it).
    local su = vim.b[buf].yap_session_usage or { prompt = 0, completion = 0 }
    su.prompt = su.prompt + (ev.prompt or 0)
    su.completion = su.completion + (ev.completion or 0)
    if ev.cost then
      su.cost = (su.cost or 0) + ev.cost
    end
    vim.b[buf].yap_session_usage = su
    append_event(buf, ev)
    local t = audits[buf]
    if t then
      audit.fold(t.bufnr, false, true)
    end
  end
end

--- :YapClear [keep] — replace the bodies of all but the last `keep`
--- (default 2) yap:tool regions with a placeholder; the full output
--- stays in the audit log. Headers (flattened into the model's transcript)
--- and yap:ui diffs stay. This is the one sanctioned rewrite of
--- existing lines (R16): the user owns the document, and clearing old
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
--- R18). Returns trimmed body lines, never a leading # @role heading.
local function compact_prompt_lines()
  local lines = require("harness.template").named_lines("compact")
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
  require("harness.template").append_as_block(buf, compact_prompt_lines())
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

--- Delete every message between the system block and the final summary
--- (the last # @assistant block), leaving frontmatter + system block +
--- summary + the trailing # @user prompt. Blank-line separation is R7.
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
  -- Keep frontmatter + the system block: the system block ends at the
  -- first heading after # @system; with no system block, keep only the
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
        se = #lines -- system block runs to the end (no later heading)
      end
      break
    elseif lines[i]:match(HEAD) then
      se = i - 1 -- no system block: keep frontmatter only
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
  kept[#kept + 1] = "" -- one blank line between system and summary (R7)
  for i = ai, #lines do
    kept[#kept + 1] = lines[i]
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, kept)
  require("harness.session").save(buf)
end

-- Drawer open/close lives in harness.drawer.

local function close_session_drawers(buf)
  local scratch = vim.b[buf].yap_scratch
  if scratch and vim.api.nvim_buf_is_valid(scratch) then
    drawer.close(scratch, buf)
  end
  local audit_view = audits[buf]
  if audit_view and vim.api.nvim_buf_is_valid(audit_view.bufnr) then
    drawer.close(audit_view.bufnr, buf)
  end
end

--- Open the session's audit view (:YapLive): one persistent rendering
--- of the audit log, not a new terminal per call. Opens even before any
--- tool has run (an empty audit view that fills as tools execute).
function M.live(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  for chat, t in pairs(audits) do
    if t.bufnr == buf then
      drawer.toggle(chat, buf, 12)
      return
    end
  end
  local t = ensure_audit(buf)
  if not drawer.toggle(buf, t.bufnr, 12) then
    return
  end
  if M.config.keymaps.live ~= "" then
    vim.keymap.set("n", M.config.keymaps.live, function()
      M.live(t.bufnr)
    end, { buffer = t.bufnr, silent = true, desc = "yap: toggle live tool output" })
  end
  if M.config.keymaps.toggle_fold ~= "" then
    vim.keymap.set("n", M.config.keymaps.toggle_fold, function()
      vim.cmd("normal! za")
    end, { buffer = t.bufnr, silent = true, desc = "yap: toggle turn fold" })
  end
  if M.config.keymaps.view_1 ~= "" then
    vim.keymap.set("n", M.config.keymaps.view_1, function()
      audit.fold_all(t.bufnr)
    end, { buffer = t.bufnr, silent = true, desc = "yap: fold all turns" })
  end
  if M.config.keymaps.view_2 ~= "" then
    vim.keymap.set("n", M.config.keymaps.view_2, function()
      audit.unfold_all(t.bufnr)
    end, { buffer = t.bufnr, silent = true, desc = "yap: unfold all turns" })
  end
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(t.bufnr), 0 })
  audit.fold(t.bufnr)
end

--- Open a chat's audit and reveal one reviewable event (ordinal in its log).
local function show_audit_event(buf, ordinal)
  if vim.api.nvim_get_current_buf() ~= buf then
    vim.api.nvim_set_current_buf(buf)
  end
  local t = ensure_audit(buf)
  local wins = vim.fn.win_findbuf(t.bufnr)
  if wins[1] then
    vim.api.nvim_set_current_win(wins[1])
  else
    M.live(buf)
  end
  local n = t.reviews[ordinal]
  if n then
    vim.api.nvim_win_set_cursor(0, { n, 0 })
    vim.cmd("normal! zvzz") -- unfold the turn and center the request with its surrounding events
  end
end

--- Focus the matching tool block in the chat without leaving the audit drawer.
--- The audit records calls even if the user later edits their transcript, so
--- a missing block simply leaves the chat cursor where it was.
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
  for _, detail in ipairs(require("harness.structure").parse(buf).details) do
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
          -- A picker selection wins over tail-following for this turn.
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

inspect_approval = function(buf, ev)
  local ordinal = 0
  local target
  for _, line in ipairs(vim.fn.readfile(paths.audit_path(buf))) do
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == "table" and (entry.type == "alert_advice" or entry.type == "approval_request") then
      ordinal = ordinal + 1
      if entry.type == "approval_request" and entry.id == ev.id and entry.ts == ev.ts then
        target = ordinal
      end
    end
  end
  -- Inspect is an audit action: keep the shield-marked request focused,
  -- with the conversation visible in the other window for context.
  if target then
    show_audit_event(buf, target)
  end
end

--- After inspecting a paused approval, explicitly answer it. The backend
--- denies on timeout; dismissing this dialog also denies.
function M.approval()
  local current = vim.api.nvim_get_current_buf()
  local buf = pending_approvals[current] and current or nil
  if not buf then
    for chat, t in pairs(audits) do
      if t.bufnr == current and pending_approvals[chat] then
        buf = chat
        break
      end
    end
  end
  if not buf then
    for chat in pairs(pending_approvals) do
      if buf then
        vim.notify("yap: multiple pending approvals; open the relevant session's audit first", vim.log.levels.WARN)
        return
      end
      buf = chat
    end
  end
  if not buf then
    vim.notify("yap: no pending approval", vim.log.levels.INFO)
    return
  end
  local ev = pending_approvals[buf]
  local choice = vim.fn.confirm(
    ("yap: approve %s in %s?\nReason: %s\n\n%s"):format(
      ev.tool or "tool",
      live_session_label(buf),
      ev.reason or "review call",
      ev.command or ""
    ),
    "&Run\n&Deny\n&Inspect",
    2,
    "Warning"
  )
  if choice == 3 then
    inspect_approval(buf, ev)
  else
    answer_approval(buf, choice == 1)
  end
end

--- Review advisories and blocked calls for this project, including sessions
--- no longer open. Each picker item lands on its own unfolded audit entry.
function M.alerts()
  local items = {}
  local audit_dir = paths.audit_dir(vim.fn.getcwd())
  local session_dir = paths.session_dir(vim.fn.getcwd())
  for _, log in ipairs(vim.fn.glob(audit_dir .. "/*.jsonl", false, true)) do
    local path = session_dir .. "/" .. vim.fn.fnamemodify(log, ":t:r") .. ".md"
    if vim.fn.filereadable(path) == 1 then
      local ordinal = 0
      local occurrences, last_call = {}, nil
      for _, line in ipairs(vim.fn.readfile(log)) do
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" then
          if ev.type == "tool_call" and ev.id then
            occurrences[ev.id] = (occurrences[ev.id] or 0) + 1
            last_call = { id = ev.id, occurrence = occurrences[ev.id] }
          elseif ev.type == "alert_advice" or ev.type == "approval_request" then
            ordinal = ordinal + 1
            -- Advisory IDs identify the call; approval IDs identify the
            -- approval dialog, so the latter uses the last executed call.
            local call = last_call
            if ev.type == "alert_advice" and ev.id and occurrences[ev.id] then
              call = { id = ev.id, occurrence = occurrences[ev.id] }
            end
            items[#items + 1] = { path = path, event = ev, ordinal = ordinal, call = call }
          end
        end
      end
    end
  end
  table.sort(items, function(a, b)
    return (a.event.ts or "") > (b.event.ts or "")
  end)
  if #items == 0 then
    vim.notify("yap: no alerts or approval requests for this project", vim.log.levels.INFO)
    return
  end
  vim.ui.select(items, {
    prompt = "yap alerts (newest first)",
    format_item = function(item)
      local ev = item.event
      return ("%s  %s  %s %s: %s"):format(
        ev.ts or "?",
        vim.fn.fnamemodify(item.path, ":t"),
        ev.type == "approval_request" and "approval requested" or "advisory",
        ev.tool or ev.name or "tool",
        ev.reason or "review call"
      )
    end,
  }, function(item)
    if not item then
      return
    end
    local path = item.path
    local buf = vim.fn.bufnr(path)
    if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_set_current_buf(buf)
      adopt(buf, path)
    else
      buf = M.open(path)
    end
    show_audit_event(buf, item.ordinal)
    focus_alert_call(buf, item.call)
  end)
end

-- The scratch queue and mid-turn steering live in harness.scratch.
--- parse-excluded marker in the buffer as a record.
local function report_error(buf, err)
  errors[buf] = err
  -- The marker is an HTML comment: neutralize any `-->` in the error
  -- text so it can't close the comment early for markdown renderers.
  local block = { "<!-- yap:error" }
  vim.list_extend(block, vim.split(err:gsub("%-%->", "-- >"), "\n", { plain = true }))
  table.insert(block, "-->")
  document.append_block(buf, block)
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
  local block = {}
  if comment_open then
    table.insert(block, "-->")
  end
  if in_tool then
    table.insert(block, "<!-- /yap:tool -->")
  end
  if #block > 0 then
    vim.api.nvim_buf_set_lines(buf, #lines, #lines, false, block)
  end
end

-- Latest description request per buffer, so a slow earlier summary cannot
-- clobber a newer one (send and turn-completion refreshes can overlap).
local description_seq = {}
local description_started = {}

-- Routine commit/close requests should not become the session's title when
-- an earlier user request explains what the work was actually about. Tool
-- calls and results are assistant transcript text, not user intent, so never
-- send them to the title model.
local function title_messages(messages)
  local user_indices = {}
  for i, message in ipairs(messages) do
    if message.role == "user" then
      user_indices[#user_indices + 1] = i
    end
  end
  if #user_indices == 0 then
    return {}, false, false
  end

  local latest = user_indices[#user_indices]
  local earlier_user = #user_indices > 1
  local text = messages[latest].content:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local lower = text:lower()
  local replacement
  local housekeeping_only = false
  if lower:match("^commit changes from this session") or lower:match("^commit( and close)?[.!]?$") then
    replacement = nil
    housekeeping_only = true
  elseif earlier_user then
    replacement = lower:match("^(.-)%s+commit and close[.!]?$")
    if replacement then
      replacement = replacement:gsub("%s+$", "")
    end
  end

  local filtered = {}
  for _, i in ipairs(user_indices) do
    if i ~= latest then
      filtered[#filtered + 1] = messages[i]
    elseif replacement and replacement ~= "" then
      filtered[#filtered + 1] = { role = "user", content = replacement }
    elseif not housekeeping_only then
      filtered[#filtered + 1] = messages[i]
    end
  end
  return filtered, housekeeping_only or replacement ~= nil, housekeeping_only
end

local function current_description(buf)
  local e = frontmatter.end_line(buf)
  if not e then
    return ""
  end
  local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
  return fm and fm.description or ""
end

--- Generate or refresh the session description shown in the winbar and
--- session picker. `kind` selects the model and what it summarizes:
---   "user"   — smallest model, only the first useful request (runs once)
---   "answer" — bigger model, the ordered user-request history (runs after turns)
local function refresh_description(buf, kind, messages)
  local combo, system, content
  local title_input, housekeeping = title_messages(messages or document.parse_buffer(buf))
  if kind == "user" then
    -- Generate an instant label only once, from the session's first useful
    -- request. Later turns are summarized by the whole-session stage below.
    if current_description(buf) ~= "" or description_started[buf] or (housekeeping and #title_input == 0) then
      return
    end
    combo = M.config.description_model
    system = [[Write a short title for the user's request below.

Rules:
- 2-5 words, a specific noun phrase, not a sentence
- No leading "The user", no "how to", no trailing period
- No colon in the title (it breaks the YAML frontmatter)
- Example: "Add websearch tool", "Fix fold lag on streaming"

Return only the title.]]
    for _, message in ipairs(title_input) do
      if message.role == "user" then
        content = message.content
        break
      end
    end
    if not content or content == "" then
      return
    end
  else
    if #title_input == 0 then
      return
    end
    combo = M.config.description_answer_model
    system = [[Write a short session title centered on the overall work, so the session is easy to find later.

The input is the user's requests in order. The first request anchors the session's main goal; later requests may refine or extend it. Summarize the overall work, not just the final request or workflow.

Rules:
- 2-6 words, a specific noun phrase, not a sentence, no trailing period
- No "session", "conversation", "the user", "about"
- Prefer "Subject – change" so titles stay distinct across sessions in the same project
- No colon in the title — it breaks the YAML frontmatter
- Routine commit/close instructions are housekeeping, not the session goal
- Never title from code, logs, or command output; do not use Markdown fences
- Example: "Fold lag – cache per changedtick"

Return only the title.]]
    local requests = {}
    for _, message in ipairs(title_input) do
      requests[#requests + 1] = message.content
    end
    local follow_ups = {}
    for i = 2, #requests do
      follow_ups[#follow_ups + 1] = requests[i]
    end
    content = vim.json.encode({ initial_request = requests[1], follow_up_requests = follow_ups })
  end
  if not combo or combo == "" then
    return
  end
  local provider, model = combo:match("^([%w_.:%-]+)/([%w_.:%-]+)$")
  if not provider then
    return
  end
  local seq = (description_seq[buf] or 0) + 1
  description_seq[buf] = seq
  if kind == "user" then
    description_started[buf] = true
  end
  local payload = vim.json.encode({
    messages = {
      { role = "system", content = system },
      { role = "user", content = content },
    },
  })
  vim.system(
    { M.config.bin, "send", "--provider", provider, "--model", model },
    { stdin = payload, text = true },
    vim.schedule_wrap(function(result)
      if not vim.api.nvim_buf_is_valid(buf) or description_seq[buf] ~= seq then
        return
      end
      if result.code ~= 0 then
        return
      end
      local description = (result.stdout or "")
        :gsub("<!%-%-.-%-%->", "")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
        :gsub(":%s+", " – ")
      if description == "" or description:find("`", 1, true) then
        return
      end
      -- The prompts ask for a 2-6 word phrase, but a verbose model can
      -- still return a paragraph; hard-cap it so the frontmatter and
      -- picker stay readable. (No max_tokens cap: reasoning models spend
      -- the whole budget on reasoning and return an empty completion.)
      if #description > 60 then
        description = description:sub(1, 59):gsub("%s+%S*$", "") .. "…"
      end
      local e = frontmatter.end_line(buf)
      if not e then
        return
      end
      local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
      if not fm then
        return
      end
      local block = frontmatter.render(
        fm.provider,
        fm.model,
        fm.models,
        fm.created_at,
        description,
        fm.role,
        fm.tools,
        fm.subagents,
        fm.updated_at,
        fm.turns,
        fm.cwd,
        fm.forked_from,
        fm.forks,
        fm.subagent_parent
      )
      vim.api.nvim_buf_set_lines(buf, 0, e, false, block)
      require("harness.session").save(buf)
    end)
  )
end

--- An undelivered steer is a draft, not a follow-up turn. Scratch text
--- remains in its file; template steering without a scratch gets copied to
--- the empty chat prompt so it cannot silently disappear.
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
    vim.notify("yap: steer was not delivered; draft is in the chat prompt (send with <C-s>)", vim.log.levels.WARN)
  end
end

--- Every stream exit, including errors and :YapStop, hands the buffer back
--- to the user in the same writable shape as a successful turn.
local function close_stream(buf)
  repair_stream_tail(buf)
  document.append_block(buf, { "# @user", "" })
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

  local messages = document.parse_buffer(buf)
  -- The harness always prepends its own boilerplate, then the
  -- request-scoped cwd: neither is stored in the buffer, so the visible
  -- session stays clean and :cd takes effect on the very next turn.
  table.insert(messages, 1, { role = "system", content = yap_about() })
  table.insert(messages, 2, {
    role = "system",
    content = "Current Neovim working directory: " .. vim.fn.getcwd(),
  })
  if #messages == 0 then
    vim.notify("yap: no message to send; write under # @user", vim.log.levels.WARN)
    return
  end

  -- Label the session from the latest user message immediately (smallest
  -- model); the final whole-session title arrives after the answer.
  refresh_description(buf, "user", messages)

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
  document.append_block(buf, { "# @assistant", "" })
  follow_tail()
  -- Sends never touch existing fold state or rewrite existing lines: the
  -- buffer is always in its final format, streaming only appends at the end,
  -- and new folds adopt the view's 'foldlevel' as they appear.
  spinner.start()
  audit_poll_start()

  local process = servers[buf]
  if not process then
    local partial = ""
    local stderr_partial = ""
    local stderr_chunks = {}
    local status, barrier
    -- Coalesce rapid per-token stdout flushes into one buffer edit per
    -- ~STREAM_FLUSH_MS: block parsing is O(n) per edit, so batching keeps a
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
      local l = live[buf]
      drain_audit(buf) -- final bytes; a killed tool never sent tool_end
      if l then
        live[buf] = nil
        vim.npcall(os.remove, l.log) -- a killed tool leaves a temp log behind
      end
      spinner.stop_if_idle()
      audit_poll_stop_if_idle()
      repair_stream_tail(buf)
      if not result.ok then
        local err = result.error or table.concat(stderr_chunks, "\n"):gsub("%s+$", "")
        report_error(buf, err ~= "" and err or "backend exited")
        close_stream(buf)
        follow_tail()
        close_if_requested(buf)
        return
      end
      consume_usage(buf)
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
      document.append_block(buf, { "# @user", "" })
      leave_undelivered_steer(buf)
      follow_tail()
      awaiting[buf] = true
      require("harness.session").save(buf)
      if subagent_done[buf] then
        local done = subagent_done[buf]
        subagent_done[buf] = nil
        done(not errors[buf])
      end
      refresh_description(buf, "answer")
      audit_follow(buf) -- first save named the session; rename the log to match
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
      audit_poll_stop_if_idle()
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
  local payload = vim.json.encode({
    provider = provider,
    model = model,
    messages = messages,
    tools = vim.b[buf].yap_tools,
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

--- Stop and wipe every child session when its parent is unloaded.
local function close_subagents(parent)
  subagent_children[parent] = nil
  for _, child in ipairs(vim.api.nvim_list_bufs()) do
    if child ~= parent and vim.b[child].yap and vim.b[child].yap_subagent_parent == parent then
      -- Closing a child must not send a late result into a parent being
      -- closed; stop it before wiping its buffer.
      subagent_done[child] = nil
      M.stop(child)
      if vim.api.nvim_buf_is_valid(child) then
        vim.npcall(vim.api.nvim_buf_delete, child, { force = true })
      end
    end
  end
end

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
    spinner.stop_if_idle()
    audit_poll_stop_if_idle()
    drain_audit(buf)
    local l = live[buf]
    if l then
      live[buf] = nil
      vim.npcall(os.remove, l.log)
    end
    local f = stream_flush[buf]
    if f then
      f()
      stream_flush[buf] = nil
    end
    repair_stream_tail(buf)
    close_stream(buf)
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
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
  -- A chat buffer is not code: markdown LSPs (semantic tokens, inlay hints)
  -- add per-redraw cost on a large session and buy nothing (R1).
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

  -- Diff hunks are meaningless on a chat transcript, and mini.diff's
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
  map("n", keys.insert_file, function()
    M.insert_file()
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

--- Open a new yap chat buffer.
function M.new(opts)
  opts = opts or {}
  local win = vim.api.nvim_get_current_win()
  local previous = vim.api.nvim_win_get_buf(win)
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  if opts.system then
    vim.b[buf].yap_system = opts.system
  end
  if opts.role then
    vim.b[buf].yap_role = opts.role
  end
  if opts.tools then
    vim.b[buf].yap_tools = opts.tools
  end
  if opts.path then
    vim.b[buf].yap_path = opts.path
    vim.api.nvim_buf_set_name(buf, opts.path)
  end
  local provider, model = M.config.provider, M.config.model
  if config.default_combo then
    provider, model = config.default_combo:match("^([%w_.:%-]+)/([%w_.:%-]+)$")
  end
  vim.b[buf].yap_provider = opts.provider or provider
  vim.b[buf].yap_model = opts.model or model
  vim.b[buf].yap_project_cwd = vim.fs.normalize(vim.fn.getcwd())

  local lines = { "# @system", "" }
  vim.list_extend(lines, vim.split(vim.b[buf].yap_system or system_prompt(), "\n", { plain = true }))
  if opts.skills_intro or M.config.skills_intro then
    local intro = require("harness.template").skills_intro_lines()
    if intro then
      vim.list_extend(lines, { "", "## Skills" })
      vim.list_extend(lines, intro)
    end
  end
  vim.list_extend(lines, { "", "# @user", "" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  frontmatter.sync(buf) -- prepend the session's model state (R1: it lives in the buffer)
  -- Create the session file up front so the buffer is file-backed from
  -- the start: `:file` names the session immediately, before the first
  -- reply. The LSP guard in setup_buffer keeps markdown clients off it
  -- regardless of the .md extension.
  require("harness.session").save(buf)
  -- The audit view is a rendering of the audit log: create its live-view buffer
  -- now (empty — the audit log is written on the first event), before any
  -- :file rename or tool run.
  ensure_audit(buf)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })

  setup_buffer(buf)
  if opts.hidden then
    vim.api.nvim_win_set_buf(win, previous)
  end

  return buf
end

-- A child has an ordinary session file and its own backend. The parent tool
-- waits in Go; a reply line to its serve process releases that tool call.
-- The tools a subagent role may request; role files also use the aliases
-- below (grep/find/webfetch) which are mapped onto these canonical names.
local ALLOWED_TOOLS = {
  "ls",
  "read",
  "search",
  "glob",
  "fetch",
  "bash",
  "python",
  "curl",
  "git",
  "write",
  "edit",
  "websearch",
  "quickfix",
  "ssh",
  "jev",
}

-- A role with no `tools:` header gets this read-only set: a subagent is one
-- prompt-injection hop removed from the user's attention, so it must opt into
-- write/bash/python/curl/ssh explicitly. Any role may still request the full
-- set (minus recursive `subagent`) via its `tools:` header.
local DEFAULT_SUBAGENT_TOOLS = { "ls", "read", "search", "glob", "fetch", "git", "websearch", "quickfix", "jev" }

local function subagent_result(parent, child, child_path, reply)
  return function(success)
    subagent_children[parent] = nil
    local result = "error: " .. (errors[child] or "subagent stopped without a result")
    if success then
      -- Only final prose, not the child's tool history, belongs in the parent.
      local text, in_comment = {}, false
      for _, line in ipairs(vim.api.nvim_buf_get_lines(child, 0, -1, false)) do
        if line == "# @assistant" then
          text, in_comment = {}, false
        elseif line:match("^<!%-%- /yap:tool") then
          text = {}
        elseif line:match("^<!%-%- yap:") then
          in_comment = not line:match("%-%->$")
        elseif in_comment then
          if line == "-->" then
            in_comment = false
          end
        elseif line ~= "# @user" then
          text[#text + 1] = line
        end
      end
      result = table.concat(text, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      if result == "" then
        result = "error: subagent returned no final answer"
      end
    end
    reply("Session: [" .. child_path .. "](" .. child_path .. ")\n" .. result)
  end
end

start_subagent = function(parent, ev)
  local function reply(text)
    local process = servers[parent]
    if process then
      process:write(vim.json.encode({ type = "subagent_result", id = ev.id, result = text }) .. "\n")
    end
  end
  if type(ev.task) ~= "string" or ev.task:match("^%s*$") then
    reply("error: invalid subagent request")
    return
  end
  if ev.session and ev.session ~= "" then
    local parent_fm = frontmatter.parse(vim.api.nvim_buf_get_lines(parent, 0, -1, false))
    local child_path = vim.fs.normalize(ev.session)
    local owned = false
    for _, path in ipairs(parent_fm and parent_fm.subagents or {}) do
      if vim.fs.normalize(path) == child_path then
        owned = true
        break
      end
    end
    if not owned or vim.fn.filereadable(child_path) == 0 then
      reply("error: subagent session not found in parent's subagents list")
      return
    end
    local child_fm = frontmatter.parse(vim.fn.readfile(child_path))
    if not child_fm or not child_fm.role or (ev.role and ev.role ~= "" and ev.role ~= child_fm.role) then
      reply("error: subagent role mismatch")
      return
    end
    local child = vim.fn.bufadd(child_path)
    vim.fn.bufload(child)
    if not vim.b[child].yap then
      adopt(child, child_path)
    end
    if running[child] then
      reply("error: subagent session is already running")
      return
    end
    document.append_message(child, "user", vim.split(ev.task, "\n", { plain = true }))
    vim.b[child].yap_subagent_parent = parent
    vim.b[child].yap_subagent_task = ev.task
    require("harness.session").save(child)
    subagent_children[parent] = child
    subagent_done[child] = subagent_result(parent, child, child_path, reply)
    M.send(child)
    return
  end
  if type(ev.role) ~= "string" or not ev.role:match("^[%w_-]+$") then
    reply("error: invalid subagent request")
    return
  end
  local role_file = paths.expand(M.config.roles_dir) .. "/" .. ev.role .. ".md"
  local ok_lines, lines = pcall(vim.fn.readfile, role_file)
  if not ok_lines or #lines == 0 or lines[1] ~= "---" then
    reply("error: missing role " .. ev.role .. " (" .. role_file .. ")")
    return
  end
  local header, closing = {}, nil
  for i = 2, #lines do
    if lines[i] == "---" then
      closing = i
      break
    end
    local key, value = lines[i]:match("^(%w+):%s*(.-)%s*$")
    if key then
      header[key] = value
    end
  end
  if not closing then
    reply("error: invalid role " .. role_file)
    return
  end
  local body = table.concat(vim.list_slice(lines, closing + 1), "\n")
  local provider, model = config.current_combo(parent)
  -- Pi roles commonly use bare model names; Yap cannot infer their provider.
  -- Only a provider/model pair overrides the known-working parent combo.
  if header.model and header.model ~= "" then
    local p, m = header.model:match("^([^/]+)/(.+)$")
    if p then
      provider, model = p, m
    end
  end
  local allowed = vim.deepcopy(DEFAULT_SUBAGENT_TOOLS)
  if header.tools and header.tools ~= "" then
    allowed = {}
    local aliases = { grep = "search", find = "glob", webfetch = "fetch" }
    local known = {}
    for _, name in ipairs(ALLOWED_TOOLS) do
      known[name] = true
    end
    for name in header.tools:gmatch("[^,%s]+") do
      name = aliases[name] or name
      if not known[name] then
        reply("error: role " .. ev.role .. " requires unsupported tool " .. name)
        return
      end
      allowed[#allowed + 1] = name
    end
  end
  local parent_path = vim.b[parent].yap_path
  local stem = parent_path:gsub("%.md$", "")
  local child_path
  repeat
    local random = vim.uv.random(3)
    child_path = stem .. "-" .. string.format("%02x%02x%02x", random:byte(1, 3)) .. ".md"
  until vim.fn.filereadable(child_path) == 0
  local ok, child = pcall(M.new, {
    path = child_path,
    system = body,
    role = ev.role,
    provider = provider,
    model = model,
    tools = allowed,
    hidden = true,
  })
  if not ok then
    reply("error: cannot create subagent: " .. tostring(child))
    return
  end
  document.append_text(child, ev.task)
  vim.b[child].yap_subagent_parent = parent
  vim.b[child].yap_subagent_task = ev.task
  local child_fm = frontmatter.parse(vim.api.nvim_buf_get_lines(child, 0, -1, false))
  local ending = frontmatter.end_line(child)
  vim.api.nvim_buf_set_lines(
    child,
    0,
    ending,
    false,
    frontmatter.render(
      child_fm.provider,
      child_fm.model,
      child_fm.models,
      child_fm.created_at,
      child_fm.description,
      child_fm.role,
      child_fm.tools,
      child_fm.subagents,
      child_fm.updated_at,
      child_fm.turns,
      child_fm.cwd,
      child_fm.forked_from,
      child_fm.forks,
      parent_path
    )
  )
  require("harness.session").save(child)
  subagent_children[parent] = child
  frontmatter.record_subagent(parent, child_path)
  subagent_done[child] = subagent_result(parent, child, child_path, reply)
  M.send(child)
end

--- Open a saved session file as a yap buffer.
--- Turn a session-file buffer into a managed yap buffer: unlisted,
--- keymapped, audit view attached, model combo resumed from
--- frontmatter. Shared by :YapSessions resume and by directly opening
--- a file under ~/.yap/sessions/.
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
    if fm and fm.role then
      vim.b[buf].yap_role = fm.role
    end
  end
  -- A reopened session that ended on `# @user` awaits the next reply;
  -- seed the overview hint so it counts before its first send here.
  winbar.seed_awaiting(buf)
  setup_buffer(buf)
  ensure_audit(buf) -- restore the live view from the audit log (create if missing)
  seed_session_usage(buf) -- durable all-time totals from the audit log
  return buf
end

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
local function focus_buf(buf)
  local wins = vim.fn.win_findbuf(buf)
  if wins[1] then
    vim.api.nvim_set_current_win(wins[1])
  else
    switch_buf(buf)
  end
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
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
    -- Reuse the in-memory buffer with its unsaved changes; `:edit` would
    -- refuse to discard them (E37).
    focus_buf(buf)
    return adopt(buf, path)
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
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
  local provider, model = combo:match("^([%w_.:%-]+)/([%w_.:%-]+)$")
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
  if not combo:match("^[%w_.:%-]+/[%w_.:%-]+$") then
    vim.notify("yap: expected provider/model, got: " .. combo, vim.log.levels.ERROR)
    return
  end
  config.write_default_combo(combo)
  vim.notify("yap: default model for new chats: " .. combo, vim.log.levels.INFO)
end

--- Session title for the picker: description when present, filename as
--- fallback. Subagents and forks are indented under their parent when it
--- is open. The project cwd is rendered separately by |M.instances|.
live_session_label = function(buf, parent)
  local name = vim.api.nvim_buf_get_name(buf)
  local path = (name ~= "" and not name:match("^%a+://")) and name or (vim.b[buf].yap_path or name)
  local e = frontmatter.end_line(buf)
  local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false)) or nil
  local session = require("harness.session")
  local label = session.label(path, fm and fm.description)
  local role = fm and fm.role or vim.b[buf].yap_role
  if role then
    local task = session.task(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    local fallback = (vim.b[buf].yap_subagent_task or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    label = role .. " · " .. ((fm and fm.description ~= "" and fm.description) or task or (fallback ~= "" and fallback) or label)
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

--- Plain state token for a buffer: the key |M.instances| filters on, and
--- the word behind each picker status glyph.
local function session_state(buf)
  if running and running[buf] then
    return "running"
  elseif errors[buf] then
    return "error"
  elseif stopped[buf] then
    return "stopped"
  elseif awaiting[buf] then
    return "waiting"
  end
  return "idle"
end

--- State glyph for the session picker, mirroring the winbar state chips.
--- The picker is static, so a fixed glyph stands in for the winbar's
--- animated spinner; the state word is omitted because the icon conveys it.
local function session_status(buf)
  local ic = M.config.icons
  local glyph = { running = ic.running, stopped = ic.stopped, error = ic.error, waiting = ic.waiting, idle = ic.idle }
  return glyph[session_state(buf)]
end

--- Find an open buffer for a saved session and return its live picker status.
local function saved_session_status(path)
  local normalized = vim.fs.normalize(path)
  -- An open history row has a state icon, even when idle; closed rows have
  -- a blank status column so their titles still align.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buf].yap then
      local name = vim.b[buf].yap_path or vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fs.normalize(name) == normalized then
        return session_status(buf)
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
  if errors[buf] then
    return 1
  elseif running and running[buf] then
    return 2
  elseif stopped[buf] then
    return 3
  elseif awaiting[buf] then
    return 5
  end
  return 4
end

--- Every open yap chat buffer, annotated with its live state and sorted with
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
      if fm and ((fm.forked_from and vim.fs.normalize(fm.forked_from) == path)
        or (fm.subagent_parent and vim.fs.normalize(fm.subagent_parent) == path)) then
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
    subagent_parent = subagent_parent or (fm and fm.subagent_parent and open_paths[vim.fs.normalize(fm.subagent_parent)])
    local fork_parent = fm and fm.forked_from and open_paths[vim.fs.normalize(fm.forked_from)]
    local parent = subagent_parent or fork_parent
    local is_subagent = fm and fm.role or vim.b[b].yap_role
    local include_current = not needs_you or (b == current and has_open_child(b))
    local child_needs_you = is_subagent and (stopped[b] or errors[b])
    if
      (b ~= current or include_current)
      and vim.b[b].yap
      and (not needs_you or not is_subagent or child_needs_you)
      and (states == nil or states[session_state(b)] or (needs_you and (child_needs_you or attention_child[b])))
    then
      items[#items + 1] = {
        buf = b,
        text = live_session_label(b, parent ~= nil),
        path = parent and "" or vim.b[b].yap_project_cwd,
        state = session_state(b),
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
      if vim.b[current].yap and states[session_state(current)] then
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
  local glyph = {
    running = M.config.icons.running,
    stopped = M.config.icons.stopped,
    error = M.config.icons.error,
    waiting = M.config.icons.waiting,
    idle = M.config.icons.idle,
  }
  local icon_width = 0
  for _, icon in pairs(glyph) do
    icon_width = math.max(icon_width, vim.fn.strdisplaywidth(icon))
  end
  vim.ui.select(items, {
    prompt = needs_you and "yap waiting" or "yap sessions",
    format_item = function(item)
      local suffix = multiple_projects and item.path and item.path ~= "" and (" (" .. item.path .. ")") or ""
      local icon = glyph[item.state]
      return icon .. string.rep(" ", icon_width - vim.fn.strdisplaywidth(icon)) .. "  "
        .. string.rep("  ", item.depth) .. item.text .. suffix
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
      steer = "⌁",
      approval = "⚠",
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
  -- Propagate the (possibly overridden) data roots to the path resolver.
  paths.dirs.sessions_dir = M.config.sessions_dir
  paths.dirs.audit_dir = M.config.audit_dir

  -- <leader>r, <leader>w, <leader>y, <leader>R and <leader>M are global:
  -- they list sessions across every buffer or change the default model, so
  -- they must work from any file, not just inside a chat. The other
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
  if M.config.keymaps.history_renamed ~= "" then
    vim.keymap.set("n", M.config.keymaps.history_renamed, function()
      M.sessions("renamed")
    end, { silent = true, desc = "yap: renamed history" })
  end
  if M.config.keymaps.change_default_model ~= "" then
    vim.keymap.set("n", M.config.keymaps.change_default_model, function()
      M.change_default_model()
    end, { silent = true, desc = "yap: change default model" })
  end

  -- Opening a file under ~/.yap/sessions/ directly (e.g. from a file
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
      -- Release the per-buffer UI state so the winbar's rollup and cache
      -- don't iterate/retain entries for buffers that are gone.
      live[args.buf] = nil
      state.live_usage[args.buf] = nil
      state.sessions[args.buf] = nil
      errors[args.buf] = nil
      last_turn[args.buf] = nil
      awaiting[args.buf] = nil
      stopped[args.buf] = nil
      description_seq[args.buf] = nil
      description_started[args.buf] = nil
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
      -- Let window/buffer transitions settle; focusing a drawer alone must
      -- not close it while the chat remains displayed in another window.
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
          close_session_drawers(buf)
        end
      end)
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
        close_subagents(buf)
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
      if not target then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(target) then
          return
        end
        local cur = vim.api.nvim_get_current_buf()
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
    return name, name:sub(1, #root + 1) == root .. "/"
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
  -- (R1), and a markdown LSP streaming semantic-token/inlay-hint updates is
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
      -- The error path already notified (R9); don't double up.
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
