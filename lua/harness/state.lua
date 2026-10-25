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
  steer_delivered = {}, -- buf -> steering text the running turn already received
  subagent_children = {}, -- parent buf -> child buf (the running subagent)
  subagent_done = {}, -- child buf -> function(success) to report its result
  pending_approvals = {}, -- session buf -> approval_request awaiting an explicit answer
  close_after_turn = {}, -- session buf -> true (a close_session side effect, honored on turn completion)
  stream_flush = {}, -- session buf -> flush() that coalesces streamed text into one buffer edit per tick
  follow_override = {}, -- session buf -> windows deliberately focused during a turn (paused tail-following)
  auto_accept = false, -- approve incoming approval requests (guard board toggle)
}

function M.is_running(buf)
  return M.running[buf] ~= nil
end

return M
