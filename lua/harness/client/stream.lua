-- The turn lifecycle: send, cancel, and the framed-stream plumbing.
--
-- One persistent serve backend per session buffer, so several sessions can
-- stream at once. Each backend keeps its own tool state (SSH connections
-- above all) for the life of its buffer; a cancelled turn (|:YapStop|)
-- unwinds over the protocol while the process — and its tool state —
-- survives. `servers` lives in harness.state (shared with the subagent and
-- scratch modules).

local M = {}

local state = require("harness.state")
local document = require("harness.model.document")
local audit = require("harness.client.audit")
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

-- Per-buffer state aliases (kept in harness.state so winbar/picker/setup
-- reach the same tables).
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
local close_after_turn = state.close_after_turn
local stream_flush = state.stream_flush
local follow_override = state.follow_override

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
  end
  -- Re-render after the result is written (and pending cleared) so an
  -- answered approval leaves the board instead of staying parked.
  guard.touch()
end
M.answer_approval = answer_approval

-- Approval is a non-blocking notification, not a modal: the turn is parked
-- (the backend waits up to five minutes) and the user answers deliberately
-- via :YapGuard. ERROR level plus the shield icon make an action-required
-- pause unmistakable.
local function notify_approval(buf, ev)
  vim.notify(
    ("yap: %s needs approval — %s: %s"):format(
      session.live_label(buf),
      ev.tool or "tool",
      ev.reason or "review call"
    ),
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

-- A first-class quickfix frame (a frontend side effect, not an audit event):
-- replaces the Neovim quickfix list. Only a live frame creates a list, so
-- persisted tool regions never replay on reopen.
local function handle_quickfix(frame)
  local entries = frame.entries
  if type(entries) ~= "table" then
    return
  end
  local items = {}
  for _, entry in ipairs(entries) do
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
  elseif ev.type == "tool_end" then
    audit.flush(buf, ev.log) -- emit any unterminated final line
    local logs = state.live_logs[buf] or {}
    logs[ev.log] = nil
    live[buf] = next(logs) and select(2, next(logs)) or nil
    -- The untruncated log is no longer needed once its bytes have streamed
    -- (a truncated log stays: its result references it).
    if ev.log and not ev.truncated then
      pcall(os.remove, ev.log)
    end
  elseif ev.type == "subagent_timeout" then
    local child = subagent_children[buf]
    if child then
      M.stop(child)
    end
  elseif ev.type == "approval_timeout" then
    pending_approvals[buf] = nil
    audit.append_event(buf, ev)
    guard.touch()
  elseif ev.type == "tool_call" then
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
  elseif code == -32602 then
    return "invalid request"
  elseif code == -32700 then
    return "malformed request"
  end
  return nil
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
  document.append_lines(buf, lines)
  -- A delegated failure is returned to the running parent as a tool result;
  -- a direct follow-up in the child should still report its own error.
  local parent = vim.b[buf].yap_subagent_parent
  if not (parent and running[parent]) then
    local category = code and error_category(code) or nil
    vim.notify("yap: " .. (category and (category .. " — ") or "") .. err, vim.log.levels.ERROR)
  end
end

--- Close dangling regions left by an interrupted stream. A cancelled
--- |:YapStop| (or a backend that died) can end mid-way through an open
--- region: a thinking comment (close with `-->`), a multi-line tool header
--- (an unterminated comment: `-->`, then the region closer), or a tool region
--- whose header landed but whose result didn't (`<!-- /yap:tool -->`). Two
--- flags suffice: model text/thinking and tool regions never interleave.
--- Idempotent; cheap enough to run on every turn exit.
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

-- Session titling (description generation) lives in harness.client.describe.
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
    session.save(buf)
    vim.notify("yap: steer was not delivered; draft is in the user prompt (send with <C-s>)", vim.log.levels.WARN)
  end
end

--- Every stream exit, including errors and :YapStop, hands the buffer back
--- to the user in the same writable shape as a successful turn.
local function close_stream(buf)
  repair_stream_tail(buf)
  document.append_lines(buf, { "# @user", "" })
  awaiting[buf] = true
  session.save(buf)
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
  local imported, attach_err = require("harness.client.attachment").import_paths(buf)
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
  table.insert(messages, 1, { role = "system", content = system.about(buf) })

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
  state.error_code[buf] = nil
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
    local function complete(result)
      finish_flush()
      sync_followers()
      running[buf] = nil
      follow_override[buf] = nil
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
        -- A user-initiated stop: the turn was cancelled but the serve
        -- process stays alive (SSH control masters and tool state survive).
        -- No error marker — the user asked for this. Clear any parked
        -- approval so the guard board reflects the settled turn.
        pending_approvals[buf] = nil
        guard.touch()
        close_stream(buf)
        follow_tail()
        close_if_requested(buf)
        return
      end
      if not result.ok then
        local code
        local err = result.error
        if type(err) == "table" then
          code, err = err.code, err.message
        end
        err = err or table.concat(stderr_chunks, "\n"):gsub("%s+$", "")
        report_error(buf, err ~= "" and err or "backend exited", code)
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
      session.save(buf)
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
        maintain.offer(buf)
      end
      -- close_session is a frontend side effect (like quickfix): the agent
      -- asked to end the session, so once the turn is fully done and the
      -- session file is saved, wipe the buffer. The BufWipeout autocmd in
      -- setup() tears down this buffer's serve backend.
      close_if_requested(buf)
    end
    local function handle_frame(frame)
      if frame.type == "text" then
        append(frame.text or "")
        return
      end
      sync_followers()
      if frame.type == "event" then
        handle_event(buf, frame.event)
      elseif frame.type == "tool_output" then
        audit.tool_output(buf, frame.log, frame.delta)
      elseif frame.type == "progress" then
        -- Throughput for the running tool, shown by the winbar beacon.
        local logs = state.live_logs[buf]
        local l = logs and logs[frame.log]
        if l then
          l.ms, l.bytes, l.lines = frame.ms, frame.bytes, frame.lines
        end
      elseif frame.type == "approval_request" then
        handle_approval_request(buf, frame)
      elseif frame.type == "subagent_request" then
        subagent.start(buf, frame)
      elseif frame.type == "quickfix" then
        handle_quickfix(frame)
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
    type = "turn",
    v = 1,
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
--- Cancel the in-flight turn for the current buffer (the backend survives).
function M.stop(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local child = subagent_children[buf]
  subagent_children[buf] = nil
  if child then
    M.stop(child)
  end
  local proc = running[buf]
  if proc then
    stopped[buf] = true
    -- Cancel just the in-flight turn, keeping the serve process alive so its
    -- tool state (SSH control masters above all) survives for the next send.
    -- The cancelled turn completes via the normal turn_complete frame, which
    -- runs complete()'s cancelled path (no error marker).
    local ok = pcall(function()
      proc:write(vim.json.encode({ type = "cancel" }) .. "\n")
    end)
    if not ok then
      -- Backend gone (killed externally): fall back to the old hard cleanup.
      servers[buf] = nil
      running[buf] = nil
      pending_approvals[buf] = nil
      spinner.stop_if_idle()
      repair_stream_tail(buf)
      close_stream(buf)
    end
  end
end

return M
