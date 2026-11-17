-- The turn lifecycle: send, cancel, and the framed-stream plumbing.
--
-- One persistent serve backend per session buffer, so several sessions can
-- stream at once. Each backend keeps its own tool state (MCP connections
-- above all) for the life of its buffer; a cancelled turn (stop())
-- unwinds over the protocol while the process — and its tool state —
-- survives. `servers` lives in harness.state (shared with the subagent and
-- scratch modules).

local M = {}

local state = require("harness.state")
local document = require("harness.model.document")
local audit = require("harness.client.audit")
local costguard = require("harness.client.costguard")
local guard = require("harness.ui.guard")
local scratchmod = require("harness.client.scratch")
local subagent = require("harness.client.subagent")
local describe = require("harness.client.describe")
local spinner = require("harness.ui.spinner")
local context = require("harness.model.context")
local frontmatter = require("harness.model.frontmatter")
local config = require("harness.config")
local paths = require("harness.path")
local session = require("harness.session")
local system = require("harness.client.system")
local maintain = require("harness.session.maintain")
local lsp = require("harness.client.lsp")
local util = require("harness.util")

-- Per-buffer state aliases (kept in harness.state so winbar/picker/setup
-- reach the same tables).
local running = state.running
local stopped = state.stopped
local live = state.live
local errors = state.errors
local last_turn = state.last_turn
local awaiting = state.awaiting
local steer = state.steer
local model_switch = state.model_switch
local servers = state.servers
local subagent_children = state.subagent_children
local subagent_done = state.subagent_done
local pending_approvals = state.pending_approvals
local close_after_turn = state.close_after_turn
local follow_override = state.follow_override
local stop_focus = {} -- buf -> window that pressed the stop key
local turn_start_ns = vim.api.nvim_create_namespace("yap_turn_start")

local function focus_stopped_prompt(buf, revise)
  local win = stop_focus[buf]
  stop_focus[buf] = nil
  if
    not win
    or not vim.api.nvim_win_is_valid(win)
    or vim.api.nvim_get_current_win() ~= win
    or vim.api.nvim_win_get_buf(win) ~= buf
  then
    return
  end
  local row = vim.api.nvim_buf_line_count(buf)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local col = revise and math.max(0, #line - 1) or 0
  vim.api.nvim_win_set_cursor(win, { row, col })
  -- Cancellation completes asynchronously. Don't pull the user back if they
  -- navigated away before entering insert mode.
  vim.schedule(function()
    if
      vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_get_current_win() == win
      and vim.api.nvim_win_get_buf(win) == buf
      and not running[buf]
      and vim.deep_equal(vim.api.nvim_win_get_cursor(win), { row, col })
    then
      vim.cmd(revise and line ~= "" and "startinsert!" or "startinsert")
    end
  end)
end

-- The live (user-merged) config table and the facade commands are reached
-- through the harness facade so this module never loads init at import time.
local function harness()
  return require("harness")
end

-- Honor a close_session request by wiping the buffer. The turn has already
-- been saved by whichever completion path reached this point.
local function close_if_requested(buf)
  if close_after_turn[buf] then
    close_after_turn[buf] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
    -- Neovim reports success but keeps the sole buffer alive. Give any
    -- remaining windows an ordinary replacement, then wipe the session.
    if vim.api.nvim_buf_is_valid(buf) then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.wo[win].winfixbuf = false
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end
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
    guard.record_result(buf, ev, approved)
  end
  -- Re-render after the result is written (and pending cleared) so an
  -- answered approval leaves the board instead of staying parked.
  guard.touch()
end
M.answer_approval = answer_approval

-- Approval is a non-blocking notification, not a modal: the turn is parked
-- (the backend waits up to five minutes) and the user answers deliberately
-- via guard(). ERROR level plus the shield icon make an action-required
-- pause unmistakable.
local function notify_approval(buf, ev)
  vim.notify(
    ("yap: %s needs approval — %s: %s"):format(session.live_label(buf), ev.tool or "tool", ev.reason or "review call"),
    vim.log.levels.ERROR,
    { title = "yap approval required", icon = harness().config.icons.approval }
  )
end

-- A guard rule matched: the turn is parked and the user answers via the
-- guard board (Run/Deny) or auto-accept. This is a top-level
-- approval_request frame (not a nested event) because it demands a reply.
local function handle_approval_request(buf, ev)
  ev.ts = os.date("%Y-%m-%dT%H:%M:%S")
  audit.append_event(buf, ev)
  pending_approvals[buf] = ev
  if state.auto_accept then
    answer_approval(buf, true)
  else
    notify_approval(buf, ev)
    guard.touch()
  end
end

-- Forward condensed child activity to the parent. Three independent effects:
-- the parent's live tail mirrors streamed child output, the parent winbar
-- shows the child's current phase, and a throttled liveness signal to the
-- parent's serve process keeps its subagent tool's inactivity deadline
-- honest. The parent model's context is untouched: progress is UI and
-- liveness only, never appended to the message history.
local function relay_subagent(buf, status, detail, delta)
  local parent = vim.b[buf] and vim.b[buf].yap_subagent_parent
  local id = vim.b[buf] and vim.b[buf].yap_subagent_id
  if not parent or not id or not vim.api.nvim_buf_is_valid(parent) then
    return
  end
  -- 1. Tail mirror (unthrottled: every byte of child output).
  if delta and delta ~= "" then
    audit.append_tail(parent, delta)
  end
  local now = vim.uv.now()
  -- 2. Winbar phase (throttled for per-token text; skipped for output bytes,
  --    which carry no phase change).
  if status ~= "output" and not (status == "text" and now - (state.subagent_last_signal[parent] or 0) < 1000) then
    local key = status .. "|" .. (detail or "")
    if state.subagent_phase[parent] ~= key then
      state.subagent_phase[parent] = key
      state.subagent_since[parent] = now
    end
    local since = state.subagent_since[parent] or now
    local label
    if status == "approval" then
      label = "subagent · awaiting approval"
    elseif status == "text" then
      label = "subagent · answering"
    elseif detail then
      label = "subagent · " .. detail
    else
      label = "subagent · working"
    end
    live[parent] = { name = label, ms = now - since }
    util.redraw_status()
  end
  -- 3. Liveness signal to the parent's serve process (throttled to 1s; an
  --    approval wait is signalled immediately so the clock suspends).
  if status ~= "approval" and now - (state.subagent_last_signal[parent] or 0) < 1000 then
    return
  end
  state.subagent_last_signal[parent] = now
  local process = servers[parent]
  if process then
    process:write(vim.json.encode({ type = "subagent_progress", id = id, status = status }) .. "\n")
  end
end

local function handle_event(buf, ev)
  if type(ev) ~= "table" then
    return
  end
  ev.ts = os.date("%Y-%m-%dT%H:%M:%S")
  if ev.type == "tool_start" and ev.log then
    local logs = state.live_logs[buf] or {}
    state.live_logs[buf] = logs
    logs[ev.log] = { name = ev.name or "tool", log = ev.log, since = os.time(), pending = "" }
    live[buf] = logs[ev.log]
    audit.tool_start(buf, ev.command or ev.name or "tool")
    relay_subagent(buf, "tool", ev.name or "tool")
  elseif ev.type == "tool_end" then
    audit.flush(buf, ev.log) -- emit any unterminated final line
    local logs = state.live_logs[buf] or {}
    logs[ev.log] = nil
    local _, next_log = next(logs)
    live[buf] = next_log
    -- The untruncated log is no longer needed once its bytes have streamed
    -- (a truncated log stays: its result references it).
    if ev.log and not ev.truncated then
      pcall(os.remove, ev.log)
    end
  elseif ev.type == "subagent_timeout" then
    local children = subagent_children[buf]
    local child = children and children[ev.id]
    if child then
      M.stop(child)
    end
  elseif ev.type == "approval_timeout" then
    local req = pending_approvals[buf]
    pending_approvals[buf] = nil
    audit.append_event(buf, ev)
    guard.record_result(buf, req, nil)
    guard.touch()
  elseif ev.type == "tool_call" then
    if ev.id then
      local counts = state.tool_call_counts[buf] or {}
      counts[ev.id] = (counts[ev.id] or 0) + 1
      state.tool_call_counts[buf] = counts
      state.last_tool_call[buf] = { id = ev.id, occurrence = counts[ev.id] }
    end
    audit.append_event(buf, ev) -- full arguments for every tool (bash renders via tool_start)
  elseif ev.type == "tool_result" then
    audit.append_event(buf, ev) -- full result; bash output already streamed above
  elseif ev.type == "retry" then
    audit.append_event(buf, ev) -- a transient generation error was retried
  elseif ev.type == "steer" then
    if steer[buf] == ev.text then
      steer[buf] = nil -- delivered: remove only the matching live draft
      local scratch = vim.b[buf].yap_scratch
      if scratch and vim.api.nvim_buf_is_valid(scratch) and scratchmod.section_text(scratch, "steer") == ev.text then
        scratchmod.set_section(scratch, "steer", {})
      end
    end
    audit.append_event(buf, ev) -- audit trail: a steering message landed mid-turn
  elseif ev.type == "model_change" then
    model_switch[buf] = nil -- delivered (or failed): the pending-switch icon clears
    audit.append_event(buf, ev) -- audit trail: a model switch landed mid-turn
  elseif ev.type == "tool_text_warning" then
    audit.append_event(buf, ev) -- the model emitted a tool call as text; nothing ran
  elseif ev.type == "error" then
    audit.append_event(buf, ev) -- a turn failed: classified code + message
  elseif ev.type == "usage" then
    -- One line per model step: the durable per-step prompt/cache split, so a
    -- tool-heavy turn's reuse can be attributed step by step instead of only
    -- as a turn average. Cumulative totals still come from turn_end
    -- (fold_usage counts turn_end alone), so this never double-counts.
    state.live_usage[buf] = ev
    audit.append_event(buf, ev)
    util.redraw_status()
  elseif ev.type == "turn_end" then
    state.live_usage[buf] = nil
    last_turn[buf] = ev -- for the User YapTurnDone event on exit
    -- The audit log is the single source of truth for usage: this folds the
    -- turn into both the since-open and all-time totals (see audit.lua).
    audit.apply_turn_end(buf, ev)
    -- A turn may have answered or expired approvals; re-render the board so
    -- it reflects the settled turn even if its own touch() raced the event.
    guard.touch()
  end
end
-- The scratch queue and mid-turn steering live in harness.client.scratch.

--- The wire error code maps to a short category the notify prefixes, so an
--- auth failure, rate limit, network error and internal error read distinctly;
--- the full message still follows. Only programmatic consumers read
--- state.error_code; the human string stays errors[buf].
local function error_category(code)
  if code == -32001 then
    return "authentication failed"
  elseif code == -32002 then
    return "rate limited"
  elseif code == -32003 then
    return "network error"
  elseif code == -32004 then
    return "context window exceeded"
  elseif code == -32005 then
    return "provider error"
  elseif code == -32602 then
    return "invalid request"
  elseif code == -32700 then
    return "malformed request"
  end
  return nil
end

--- Remove the incomplete assistant turn and return to the prompt that
--- started it. The extmark follows edits above the streaming reply.
local function restore_prompt(buf, anchor)
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, turn_start_ns, anchor, {})
  vim.api.nvim_buf_del_extmark(buf, turn_start_ns, anchor)
  if #mark == 0 then
    return
  end
  local first = mark[1]
  if first > 0 and vim.api.nvim_buf_get_lines(buf, first - 1, first, false)[1] == "" then
    first = first - 1 -- remove the separator inserted before # @assistant
  end
  local fold = require("harness.ui.fold")
  fold.before_change(buf)
  vim.api.nvim_buf_set_lines(buf, first, -1, false, {})
  fold.after_append(buf)
end

--- Report an error and record it as a parse-excluded marker in the buffer.
--- `code` is the wire error code (nil for a backend exit, which is
--- classed as internal); it selects the notify category and is stored in
--- state.error_code for programmatic consumers.
local function report_error(buf, err, code)
  errors[buf] = err
  state.error_code[buf] = code
  -- The marker is an HTML comment: neutralize any `-->` in the error
  -- text so it can't close the comment early for markdown renderers.
  local lines = { "<!-- yap:error" }
  vim.list_extend(lines, vim.split(err:gsub("%-%->", "-- >"), "\n", { plain = true }))
  table.insert(lines, "-->")
  -- Keep the restored user prompt last, so the cursor lands in the draft,
  -- not on the error record. The marker is never sent to the provider.
  local headings = require("harness.model.structure").parse(buf).headings
  local heading = headings[#headings]
  if heading and heading.role == "user" then
    local fold = require("harness.ui.fold")
    fold.before_change(buf)
    -- The heading already sits behind one blank line (R-blank-lines). Only
    -- add a leading separator when a hand edit glued content to the heading.
    local prev = vim.api.nvim_buf_get_lines(buf, heading.line - 2, heading.line - 1, false)[1]
    local marker = {}
    if prev and prev:match("%S") then
      marker[#marker + 1] = ""
    end
    vim.list_extend(marker, lines)
    marker[#marker + 1] = ""
    vim.api.nvim_buf_set_lines(buf, heading.line - 1, heading.line - 1, false, marker)
    fold.after_append(buf)
  else
    document.append_lines(buf, lines)
  end
  -- A delegated failure is returned to the running parent as a tool result;
  -- a direct follow-up in the child should still report its own error.
  local parent = vim.b[buf].yap_subagent_parent
  if not (parent and running[parent]) then
    local category = code and error_category(code) or nil
    vim.notify("yap: " .. (category and (category .. " — ") or "") .. err, vim.log.levels.ERROR)
  end
end

--- Close dangling regions left by an interrupted stream. A cancelled
--- stop() (or a backend that died) can end mid-way through an open
--- region: a thinking comment (close with `-->`), a multi-line tool header
--- (an unterminated comment: `-->`, then the region closer), or a tool region
--- whose header landed but whose result didn't (`<!-- /yap:tool -->`). The
--- structural parse already knows which regions are still open — and, unlike a
--- raw line scan, is not fooled by a marker quoted inside a fence.
--- Idempotent; cheap enough to run on every turn exit.
local function repair_stream_tail(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local open = require("harness.model.structure").open_tail(buf)
  local repair = {}
  if open.comment then
    table.insert(repair, "-->")
  end
  if open.tool then
    table.insert(repair, "<!-- /yap:tool -->")
  end
  if #repair > 0 then
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, repair)
  end
end

-- An undelivered steer becomes a user draft so it cannot silently disappear.
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
    vim.notify("yap: steer was not delivered; draft remains in scratch (send again with <C-s>)", vim.log.levels.WARN)
  else
    document.append_message(buf, "user", vim.split(text, "\n", { plain = true }))
    session.save(buf)
    vim.notify("yap: steer was not delivered; draft is in the user prompt (send with <C-s>)", vim.log.levels.WARN)
  end
end

--- The three terminal dispositions are mutually exclusive and each persists
--- until the next send: awaiting (success), stopped (cancel), errors (failure).
--- `stopped` doubles as the unwinding signal while running[buf] is still set,
--- which is why the winbar reads `busy and stopped` and `not busy and stopped`
--- as two moments of the same stop.
local function close_stream(buf, outcome, anchor, err, code)
  repair_stream_tail(buf)
  awaiting[buf] = nil
  if outcome == "ok" then
    stopped[buf] = nil
    vim.api.nvim_buf_del_extmark(buf, turn_start_ns, anchor)
    document.append_lines(buf, { "# @user", "" })
    awaiting[buf] = true
  elseif outcome == "stopped" then
    stopped[buf] = true
    close_after_turn[buf] = nil
    restore_prompt(buf, anchor)
  else -- "error"
    stopped[buf] = nil
    close_after_turn[buf] = nil
    restore_prompt(buf, anchor)
    report_error(buf, err, code)
  end
  vim.b[buf].yap_turn_anchor = nil
  model_switch[buf] = nil
  if outcome ~= "ok" then
    state.clear_queued[buf] = nil
  end
  session.save(buf)
  leave_undelivered_steer(buf)
  if subagent_done[buf] then
    local done = subagent_done[buf]
    subagent_done[buf] = nil
    done(outcome == "ok")
  end
end
--- Serialize the current buffer and stream the assistant reply into it.
function M.send(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if running[buf] then
    vim.notify("yap: turn already running; press <C-c> (or call stop()) to interrupt it", vim.log.levels.WARN)
    return false
  end
  -- A missing binary is not a startup error: surface it once, actionably,
  -- the first time a managed session starts a turn (LSP attach warns too),
  -- and re-check every send so a binary installed later is picked up.
  if not lsp.bin_available() then
    lsp.warn_missing_bin()
    return false
  end
  -- A close request is scoped to the turn that made it: a stale flag from
  -- a previous errored or stopped turn must not close a later turn.
  close_after_turn[buf] = nil

  -- Import standalone photo paths before parsing or starting the turn. The
  -- resulting reference is visible in the buffer and survives later sends.
  local imported, attach_err = require("harness.client.attachment").import_paths(buf)
  if not imported then
    vim.notify("yap: " .. attach_err, vim.log.levels.WARN)
    return false
  end
  -- Child tool permissions are chosen by the caller. A hand-edited child
  -- frontmatter with an empty/missing list must never become unrestricted.
  local fm_end = frontmatter.end_line(buf)
  local fm = fm_end and frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, fm_end, false))
  if fm and fm.subagent_parent and (not fm.tools or #fm.tools == 0) then
    vim.notify("yap: subagent has no permitted tools; set tools in frontmatter", vim.log.levels.WARN)
    return false
  end
  -- Ask the backend what this send would contain: the empty-send guard and
  -- session titling both need real messages, and the transcript → request
  -- conversion is Go-owned (R-single-reader). One query, two consumers.
  -- nil means no document server is attached, so the backend validates the
  -- request itself and titling is skipped.
  local messages = document.messages(buf)
  if messages and #messages == 0 then
    vim.notify("yap: no message to send; write under # @user", vim.log.levels.WARN)
    return
  end

  -- Label the session from the latest user message before transient context
  -- is appended, so the title model never sees a context tail.
  describe.refresh(buf, "user", messages)

  -- Transient context is appended to the trailing user message by the
  -- backend (R-request-context-tail), not here.
  local extra = context.snapshot()
  -- The harness's own boilerplate is a stable system prefix, kept first so
  -- it never perturbs the prompt cache.
  local system_prompt = system.about(buf)

  -- A refused pre-flight send has not started a turn: keep the previous
  -- disposition until the cost guard has actually authorized this one.
  -- provider/model come from the buffer vars (set by new() /
  -- change_model()), falling back to config; sync them so the winbar
  -- and this send agree.
  local provider, model = config.current_combo(buf)
  vim.b[buf].yap_provider = provider
  vim.b[buf].yap_model = model
  state.live_usage[buf] = nil

  -- The cost guard runs before anything is written or spawned, so a turn that
  -- would cost more than the configured threshold asks first and spends
  -- nothing when the answer is no. Every send route funnels through here; a
  -- subagent is never blocked because it has nobody to answer (R-cost-guard).
  if not costguard.check(buf, provider .. "/" .. model, messages, fm ~= nil and fm.subagent_parent ~= nil) then
    return false
  end
  errors[buf] = nil
  state.error_code[buf] = nil
  stopped[buf] = nil
  awaiting[buf] = nil
  model_switch[buf] = nil

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
  local turn_anchor = vim.api.nvim_buf_set_extmark(buf, turn_start_ns, vim.api.nvim_buf_line_count(buf) - 2, 0, { right_gravity = false })
  vim.b[buf].yap_turn_anchor = turn_anchor
  follow_tail()
  -- Sends never touch existing fold state or rewrite existing lines: the
  -- buffer is always in its final format, streaming only appends at the end,
  -- and new folds adopt the view's 'foldlevel' as they appear.
  spinner.start()

  local process = servers[buf]
  if not process then
    local partial = ""
    local stderr_partial = ""
    local stderr_chunks = {}
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
    local function complete(result)
      -- The serve process outlives a turn. Its stdout callback was created
      -- on the first send, so read the current turn's anchor, not that
      -- callback's captured first-turn local.
      local turn_anchor = vim.b[buf].yap_turn_anchor
      if not result.cancelled then
        stop_focus[buf] = nil
      end
      finish_flush()
      sync_followers()
      running[buf] = nil
      spinner.cancel(buf)
      lsp.notify_streaming(buf, false)
      follow_override[buf] = nil
      scratchmod.refresh(vim.b[buf].yap_scratch)
      local stderr = table.concat(stderr_chunks, "\n"):gsub("%s+$", "")
      stderr_chunks = {}
      local compact = vim.b[buf].yap_compact_pending
      vim.b[buf].yap_compact_pending = nil
      audit.flush(buf) -- emit any unterminated final line
      for path in pairs(state.live_logs[buf] or {}) do
        pcall(os.remove, path)
      end
      state.live_logs[buf] = nil
      live[buf] = nil
      spinner.stop_if_idle()
      repair_stream_tail(buf)
      if result.cancelled then
        pending_approvals[buf] = nil
        guard.touch()
        scratchmod.finish_queue(buf, false)
        close_stream(buf, "stopped", turn_anchor)
        follow_tail()
        close_if_requested(buf)
        focus_stopped_prompt(buf, true)
        return
      end
      if not result.ok then
        local code
        local err = result.error
        if type(err) == "table" then
          code, err = err.code, err.message
        end
        err = err or stderr
        scratchmod.finish_queue(buf, false)
        close_stream(buf, "error", turn_anchor, err ~= "" and err or "backend exited", code)
        follow_tail()
        close_if_requested(buf)
        return
      end
      local embedded_error
      do
        local p = require("harness.model.structure").parse(buf)
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local anchor_line = vim.api.nvim_buf_get_extmark_by_id(buf, turn_start_ns, turn_anchor, {})[1] or #lines
        for _, r in ipairs(p.regions) do
          if r.kind == "error" and r.start > anchor_line then
            embedded_error = lines[r.start + 1]
          end
        end
      end
      if embedded_error then
        scratchmod.finish_queue(buf, false)
        close_stream(buf, "error", turn_anchor, embedded_error)
        follow_tail()
        close_if_requested(buf)
        return
      end
      close_stream(buf, "ok", turn_anchor)
      follow_tail()
      local queued_clear = state.clear_queued[buf]
      if queued_clear ~= nil then
        state.clear_queued[buf] = nil
        maintain.clear(buf, queued_clear)
      end
      session.save(buf)
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
        maintain.offer(buf)
      end
      -- close_session is a frontend side effect: the agent asked to end the
      -- session, so once the turn is fully done and the session file is
      -- saved, wipe the buffer. The BufWipeout autocmd in
      -- setup() tears down this buffer's serve backend.
      close_if_requested(buf)
      scratchmod.finish_queue(buf, not errors[buf])
      util.redraw_status()
    end
    local function handle_frame(frame)
      if frame.type == "text" then
        append(frame.text or "")
        relay_subagent(buf, "text")
        return
      end
      sync_followers()
      if frame.type == "event" then
        handle_event(buf, frame.event)
      elseif frame.type == "tool_output" then
        audit.tool_output(buf, frame.log, frame.delta)
        relay_subagent(buf, "output", nil, frame.delta)
      elseif frame.type == "progress" then
        -- Throughput for the running tool, shown by the winbar beacon.
        local logs = state.live_logs[buf]
        local l = logs and logs[frame.log]
        if l then
          l.ms, l.bytes, l.lines = frame.ms, frame.bytes, frame.lines
        end
      elseif frame.type == "approval_request" then
        handle_approval_request(buf, frame)
        relay_subagent(buf, "approval", frame.tool or "tool")
      elseif frame.type == "subagent_request" then
        subagent.start(buf, frame)
      elseif frame.type == "close_session" then
        -- Defer to turn completion so the reply streams out and the session
        -- file is saved before the buffer is wiped (complete() below).
        close_after_turn[buf] = true
      elseif frame.type == "turn_complete" then
        complete({
          ok = frame.ok == true,
          cancelled = frame.cancelled == true,
          error = frame.error,
        })
        return
      end
      follow_tail()
    end
    local handle
    local ok, started = pcall(
      vim.system,
      { harness().config.bin, "serve" },
      {
        stdin = true,
        text = true,
        stdout = vim.schedule_wrap(function(_, data)
          if not data or servers[buf] ~= handle then
            return
          end
          partial = partial .. data
          while true do
            local i = partial:find("\n", 1, true)
            if not i then
              break
            end
            local line = partial:sub(1, i - 1)
            partial = partial:sub(i + 1)
            if line == "" then
              -- skip an empty frame line
            else
              local ok, frame = pcall(vim.json.decode, line)
              if ok and type(frame) == "table" and frame.type then
                handle_frame(frame)
              else
                -- A non-frame line on stdout is unexpected (the agent emits
                -- only frames here); surface it as error text, never as buffer.
                table.insert(stderr_chunks, line)
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
            table.insert(stderr_chunks, line)
          end
        end),
      },
      vim.schedule_wrap(function(result)
        if servers[buf] ~= handle then
          return
        end
        servers[buf] = nil
        pending_approvals[buf] = nil
        partial = "" -- an incomplete frame at exit is discarded (killed process)
        if stderr_partial ~= "" then
          table.insert(stderr_chunks, stderr_partial)
        end
        if running[buf] then
          local stderr = table.concat(stderr_chunks, "\n")
          complete({
            ok = false,
            cancelled = stopped[buf] == true,
            error = stderr:match("%S") and stderr or ("exit " .. result.code),
          })
        end
      end)
    )
    if not ok then
      running[buf] = nil
      spinner.cancel(buf)
      spinner.stop_if_idle()
      scratchmod.finish_queue(buf, false)
      close_stream(buf, "error", turn_anchor, tostring(started))
      follow_tail()
      return false
    end
    handle = started
    servers[buf] = handle
    process = handle
  end

  running[buf] = process
  spinner.begin(buf)
  lsp.notify_streaming(buf, true)
  scratchmod.refresh(vim.b[buf].yap_scratch)
  -- The frontmatter `tools` list is the per-session allowlist: hand-edit it
  -- (remove lines) to retract tools, effective on this send. A missing or
  -- empty list means unrestricted (all tools).
  local tools = fm and fm.tools and #fm.tools > 0 and fm.tools or nil
  local payload = vim.json.encode({
    type = "turn",
    v = 1,
    provider = provider,
    model = model,
    -- The raw transcript, not flattened messages: the backend owns the
    -- send conversion (R-single-reader). System is the About Yap prefix;
    -- context is the transient tail appended to the trailing user
    -- message by the backend (R-request-context-tail).
    transcript = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
    system = system_prompt,
    context = extra,
    tools = tools,
    -- Request-only (like the context tail): the backend's own cwd is fixed
    -- when the buffer spawns it, so the live cwd keeps the tools' documented
    -- "default: the Neovim cwd" true after a :cd.
    cwd = vim.fn.getcwd(),
    -- The session's assets/ folder: transient tool files (live-tail logs,
    -- inline scripts, header files) land here instead of /tmp.
    assets_dir = paths.assets_dir(buf),
    -- The sessions root: the `sessions` tool scopes its list/search/read to
    -- this, so the model can reach other saved sessions.
    sessions_dir = paths.sessions_root(),
  }) .. "\n"
  local ok, err = pcall(function()
    process:write(payload)
  end)
  if not ok then
    servers[buf] = nil
    running[buf] = nil
    process:kill(15)
    spinner.cancel(buf)
    spinner.stop_if_idle()
    lsp.notify_streaming(buf, false)
    follow_override[buf] = nil
    scratchmod.finish_queue(buf, false)
    close_stream(buf, "error", turn_anchor, tostring(err))
    follow_tail()
    return false
  end
  return true
end
--- Cancel the in-flight turn for the current buffer (the backend survives).
function M.stop(buf, opts)
  buf = buf or vim.api.nvim_get_current_buf()
  if opts and opts.focus and running[buf] then
    stop_focus[buf] = vim.api.nvim_get_current_win()
  end
  local children = subagent_children[buf]
  if children then
    for _, child in pairs(children) do
      M.stop(child)
    end
  end
  scratchmod.finish_queue(buf, false) -- also retract a scheduled follow-up
  local proc = running[buf]
  if proc then
    if stopped[buf] then
      -- The first stop asked the backend to unwind. Do not wait for a stuck
      -- tool or provider on the second press; the exit callback finishes the
      -- cancelled turn and the next send starts a fresh serve process.
      -- SIGTERM lets the backend kill tracked tool process groups before it
      -- exits; SIGKILL here would orphan a running bash command.
      proc:kill(15)
      vim.defer_fn(function()
        if servers[buf] == proc and running[buf] == proc then
          proc:kill(9) -- teardown itself is stuck; do not hold the session hostage
        end
      end, 500)
      return
    end
    stopped[buf] = true
    -- Ask the backend to finish the current model step and its tool batch,
    -- then stop before starting another step. The turn context remains live,
    -- so an in-flight bash command can complete normally.
    local ok = pcall(function()
      proc:write(vim.json.encode({ type = "cancel" }) .. "\n")
    end)
    if not ok then
      -- Backend gone (killed externally): fall back to the old hard cleanup.
      servers[buf] = nil
      running[buf] = nil
      spinner.cancel(buf)
      pending_approvals[buf] = nil
      spinner.stop_if_idle()
      close_stream(buf, "stopped", vim.b[buf].yap_turn_anchor)
      focus_stopped_prompt(buf, true)
    end
  end
end

return M
