-- Shared mutable state for the yap harness: the per-buffer maps the winbar,
-- send/backend orchestration and session picker all read and write.
-- Centralizing them here is what lets winbar, stream, buffers and sessions
-- each live in their own module while reaching into the same tables.

local M = {
  sessions = {}, -- buf -> true (every open yap session, for the global rollup)
  running = {}, -- buf -> vim.SystemObj (in-flight send process)
  servers = {}, -- buf -> vim.SystemObj (persistent serve backend)
  stopped = {}, -- buf -> true (manually interrupted turn)
  live = {}, -- buf -> most recently started running tool (winbar)
  live_logs = {}, -- buf -> log path -> running log state (tool_output frames feed the tail)
  live_usage = {}, -- buf -> provider-reported usage accumulated during this turn
  errors = {}, -- buf -> error string (winbar + session picker)
  error_code = {}, -- buf -> wire error code (from turn_complete, for branchable handling)
  last_turn = {}, -- buf -> turn_end event (User YapTurnDone data)
  awaiting = {}, -- buf -> true (turn complete, awaiting user reply)
  steer = {}, -- buf -> pending steering text (sent mid-turn, not yet delivered)
  model_switch = {}, -- buf -> true (a mid-turn model switch is pending delivery)
  subagent_children = {}, -- parent buf -> { request id -> child buf } (running subagents)
  subagent_done = {}, -- child buf -> function(success) to report its result
  subagent_since = {}, -- parent buf -> uv.now() ms (start of the current child phase)
  subagent_phase = {}, -- parent buf -> "status|detail" key (detect a phase change)
  subagent_pending = {}, -- parent buf -> partial mirrored tail line from a child
  subagent_last_signal = {}, -- parent buf -> uv.now() ms (throttle the progress signal)
  pending_approvals = {}, -- session buf -> approval_request awaiting an explicit answer
  last_tool_call = {}, -- session buf -> { id, occurrence } of the most recent tool call
  tool_call_counts = {}, -- session buf -> { [tool call id] = occurrences }
  settled_approvals = {}, -- resolved guard rows (granted/denied/timeout) recorded this Neovim process
  close_after_turn = {}, -- session buf -> true (a close_session side effect, honored on turn completion)
  follow_override = {}, -- session buf -> windows deliberately focused during a turn (paused tail-following)
  auto_accept = false, -- approve incoming approval requests (guard board toggle)
}

function M.is_running(buf)
  return M.running[buf] ~= nil
end

return M
