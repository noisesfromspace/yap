-- `c` on the guard board clears the settled decision history: it writes a
-- project watermark (guard.json) that hides settled rows at or before it, and
-- leaves parked approvals alone. The audit log is intact, and settled rows
-- newer than the watermark still show after the clear.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local state = require("harness.state")
local paths = require("harness.path")
local guard = require("harness.ui.guard")

local a = yap.new({ provider = "mock", model = "m1" })

-- A settled (denied) approval persisted in the audit log.
local log = paths.audit_path(a)
vim.fn.mkdir(vim.fn.fnamemodify(log, ":h"), "p")
local now = os.time()
local function ts(secs)
  return os.date("%Y-%m-%dT%H:%M:%S", now + secs)
end
vim.fn.writefile({
  vim.json.encode({ type = "tool_call", id = "res", name = "bash", args = '{"command":"rm -rf x"}' }),
  vim.json.encode({
    type = "approval_request",
    id = "res",
    tool = "bash",
    command = '{"command":"rm -rf x"}',
    reason = "clear-me resolved",
    ts = ts(0),
  }),
  vim.json.encode({ type = "approval_result", id = "res", approved = false, ts = ts(0) }),
}, log, "a")

-- A live parked approval: `c` must NOT deny it.
state.pending_approvals[a] = {
  id = "parked-1",
  tool = "bash",
  command = vim.json.encode({ command = "rm -rf /" }),
  reason = "clear-me parked",
  ts = ts(0),
}

guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(board) == "yap://guard", "guard board did not open")
local text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("clear-me parked", 1, true), "parked approval missing")
assert(text:find("clear-me resolved", 1, true), "settled approval missing")

-- `c` clears the history but leaves the parked approval parked.
vim.api.nvim_feedkeys("c", "mtx", false)
assert(state.pending_approvals[a] ~= nil, "c denied a parked approval")
text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("clear-me parked", 1, true), "parked approval should stay after clear: " .. text)
assert(text:find("clear-me resolved", 1, true) == nil, "settled approval not cleared: " .. text)

-- The watermark persists across a close/reopen.
local gpath = paths.session_dir(vim.fn.getcwd()) .. "/guard.json"
assert(vim.fn.filereadable(gpath) == 1, "guard.json watermark not written")
guard.toggle() -- close
guard.toggle() -- reopen
text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("clear-me resolved", 1, true) == nil, "clear did not persist across reopen: " .. text)

-- A newer settled row still shows: the watermark hides only cleared history.
vim.fn.writefile({
  vim.json.encode({
    type = "approval_request",
    id = "later",
    tool = "bash",
    command = '{"command":"echo later"}',
    reason = "later resolved",
    ts = ts(10),
  }),
  vim.json.encode({ type = "approval_result", id = "later", approved = true, ts = ts(10) }),
}, log, "a")
guard.touch()
text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("later resolved", 1, true), "new settled row after clear should show: " .. text)
assert(text:find("clear-me resolved", 1, true) == nil, "cleared settled row still visible: " .. text)

guard.toggle() -- close
state.pending_approvals[a] = nil
print("OK guard clear")
