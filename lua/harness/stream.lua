-- Stream state shared by orchestration and UI. Keeping these maps here avoids
-- making init.lua the owner of backend lifecycle state.
local M = { running = {}, live = {}, errors = {}, last_turn = {} }
function M.is_running(buf) return M.running[buf] ~= nil end
return M
