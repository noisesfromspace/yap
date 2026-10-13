-- `c` on the guard board clears both sections: parked approvals are denied
-- (the safe answer) and advisories/settled history are hidden by a persisted
-- project watermark. The audit log is left intact, and newer events still
-- show.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local state = require("harness.state")
local paths = require("harness.path")
local guard = require("harness.guard")

local a = yap.new({ provider = "mock", model = "m1" })

-- Persisted advisory + settled approval in the audit log.
local log = paths.audit_path(a)
vim.fn.mkdir(vim.fn.fnamemodify(log, ":h"), "p")
local now = os.time()
local function ts(secs)
  return os.date("%Y-%m-%dT%H:%M:%S", now + secs)
end
vim.fn.writefile({
  vim.json.encode({ type = "tool_call", id = "adv", name = "bash", args = '{"command":"echo warning"}' }),
  vim.json.encode({
    type = "alert_advisory",
    id = "adv",
    name = "bash",
    reason = "clear-me advisory",
    ts = ts(0),
  }),
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

-- A live parked approval; a fake serve backend lets clear() exercise the
-- real deny path (writes an approval_result), which the watermark must hide.
state.servers[a] = { write = function() end }
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
assert(text:find("▸ Guard (2)", 1, true), "Guard section missing items: " .. text)
assert(text:find("clear-me parked", 1, true), "parked approval missing")
assert(text:find("clear-me resolved", 1, true), "settled approval missing")
assert(text:find("▸ Advisory (1)", 1, true), "Advisory section missing items: " .. text)
assert(text:find("clear-me advisory", 1, true), "advisory missing")

-- `c` clears every item.
vim.api.nvim_feedkeys("c", "mtx", false)
assert(state.pending_approvals[a] == nil, "c did not clear the parked approval")
text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("▸ Guard (0)", 1, true), "Guard not empty after clear: " .. text)
assert(text:find("▸ Advisory (0)", 1, true), "Advisory not empty after clear: " .. text)

-- The watermark persists across a close/reopen.
local gpath = paths.session_dir(vim.fn.getcwd()) .. "/guard.json"
assert(vim.fn.filereadable(gpath) == 1, "guard.json watermark not written")
guard.toggle() -- close
guard.toggle() -- reopen
text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("▸ Guard (0)", 1, true), "clear did not persist across reopen: " .. text)
assert(text:find("▸ Advisory (0)", 1, true), "clear did not persist across reopen: " .. text)

-- A newer advisory still shows: the watermark hides only cleared history.
vim.fn.writefile({
  vim.json.encode({
    type = "alert_advisory",
    id = "later",
    name = "bash",
    reason = "later advisory",
    ts = ts(2),
  }),
}, log, "a")
guard.touch()
text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("later advisory", 1, true), "new advisory after clear should show: " .. text)
assert(text:find("clear-me advisory", 1, true) == nil, "cleared advisory still visible: " .. text)

guard.toggle() -- close
state.servers[a] = nil
print("OK guard clear")
