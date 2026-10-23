-- Live tool tail follows only windows whose cursor is on its last line.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local audit = require("harness.client.audit")
local state = require("harness.state")

local session = vim.api.nvim_create_buf(true, true)
vim.api.nvim_buf_set_name(session, "tail-follow-test")
audit.tool_start(session, "echo start")
local tail = audit.view(session).bufnr
vim.api.nvim_set_current_buf(tail)
local win = vim.api.nvim_get_current_win()
state.live_logs[session] = { test = { log = "test" } }
local function output(n)
  local lines = {}
  for i = 1, n do
    lines[#lines + 1] = "output " .. i
  end
  audit.tool_output(session, "test", table.concat(lines, "\n") .. "\n")
end
local function cursor()
  return vim.api.nvim_win_get_cursor(win)[1]
end
local function count()
  return vim.api.nvim_buf_line_count(tail)
end

-- Starting on the tail follows even after the end has scrolled off-screen.
output(40)
output(1)
assert(cursor() == count(), "tail cursor did not follow output")
assert(vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end) > 1, "tail view did not scroll")

-- Scrolling just one line above the tail pauses following, even when it is
-- still visible in the window (the old near-bottom heuristic moved it).
vim.api.nvim_win_set_cursor(win, { count() - 1, 0 })
local parked = cursor()
output(1)
assert(cursor() == parked, "cursor just above the tail was dragged down")

-- G rejoins; a second window parked higher up remains untouched.
vim.cmd("normal! G")
vim.cmd("vsplit")
local other = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(other, { 1, 0 })
output(3)
assert(vim.api.nvim_win_get_cursor(win)[1] == count(), "G did not rejoin the tail")
assert(vim.api.nvim_win_get_cursor(other)[1] == 1, "parked window followed the tail")

print("OK tail follow")
