-- Shared mutable state for the yap harness: the per-buffer maps the winbar,
-- send/backend orchestration and session picker all read and write.
-- Centralizing them here (instead of forward-declaring locals in init.lua)
-- is what lets winbar live in its own module while the send path still
-- reaches into the same tables.

local M = {
  sessions = {}, -- buf -> true (every open yap session, for the global rollup)
  running = {}, -- buf -> vim.SystemObj (in-flight send process)
  servers = {}, -- buf -> vim.SystemObj (persistent serve backend)
  stopped = {}, -- buf -> true (manually interrupted turn)
  live = {}, -- buf -> most recently started running tool (winbar)
  live_logs = {}, -- buf -> log path -> running log state (audit drains all)
  live_usage = {}, -- buf -> provider-reported usage accumulated during this turn
  errors = {}, -- buf -> error string (winbar + session picker)
  last_turn = {}, -- buf -> turn_end event (User YapTurnDone data)
  awaiting = {}, -- buf -> true (turn complete, awaiting user reply)
  steer = {}, -- buf -> pending steering text (sent mid-turn, not yet delivered)
  subagent_children = {}, -- parent buf -> child buf (the running subagent)
  subagent_done = {}, -- child buf -> function(success) to report its result
  pending_approvals = {}, -- session buf -> approval_request awaiting an explicit answer
}

function M.is_running(buf)
  return M.running[buf] ~= nil
end

return M
