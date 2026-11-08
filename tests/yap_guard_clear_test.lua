-- `c` on the guard board clears the settled decision history recorded this
-- Neovim process, and leaves parked approvals alone. There is no guard.json
-- watermark anymore: the board is bound to this Neovim process, so clearing
-- is in-memory and the audit log is untouched.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})
local state = require("harness.state")
local guard = require("harness.ui.guard")

local a = yap.new({ provider = "mock", model = "m1" })

-- One settled (denied) approval and one live parked approval.
guard.record_result(a, {
  id = "res",
  tool = "bash",
  command = '{"command":"rm -rf x"}',
  reason = "clear-me resolved",
}, false)
state.pending_approvals[a] = {
  id = "parked-1",
  tool = "bash",
  command = vim.json.encode({ command = "rm -rf /" }),
  reason = "clear-me parked",
  ts = os.date("%Y-%m-%dT%H:%M:%S"),
}

guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.fn.bufname(board) == "Yap Guard", "guard board did not open")
local text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("clear-me parked", 1, true), "parked approval missing")
assert(text:find("clear-me resolved", 1, true), "settled approval missing")

-- `c` clears the history but leaves the parked approval parked.
vim.api.nvim_feedkeys("c", "mtx", false)
assert(state.pending_approvals[a] ~= nil, "c denied a parked approval")
text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("clear-me parked", 1, true), "parked approval should stay after clear: " .. text)
assert(text:find("clear-me resolved", 1, true) == nil, "settled approval not cleared: " .. text)

-- The clear persists across a close/reopen (in memory, same Neovim process).
guard.toggle() -- close
guard.toggle() -- reopen
text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("clear-me resolved", 1, true) == nil, "clear did not persist across reopen: " .. text)

-- A settled row recorded after the clear shows again.
guard.record_result(a, {
  id = "later",
  tool = "bash",
  command = '{"command":"echo later"}',
  reason = "later resolved",
}, true)
guard.touch()
text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("later resolved", 1, true), "new settled row after clear should show: " .. text)
assert(text:find("clear-me resolved", 1, true) == nil, "cleared settled row still visible: " .. text)

-- No guard.json watermark is written anymore.
local paths = require("harness.path")
local gf = paths.session_dir(vim.fn.getcwd()) .. "/guard.json"
assert(vim.fn.filereadable(gf) == 0, "c still writes a guard.json watermark")

guard.toggle() -- close
state.pending_approvals[a] = nil
print("OK guard clear")
