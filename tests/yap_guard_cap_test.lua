-- The guard board caps its settled-history readback (30 rows), but a parked
-- approval is live state and always shown first: a backlog of settled rows
-- must never hide a parked approval.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local state = require("harness.state")
local paths = require("harness.path")
local guard = require("harness.ui.guard")

local a = yap.new({ provider = "mock", model = "m1" })

-- 31 resolved approvals in one audit log.
local sdir = paths.session_dir(vim.fn.getcwd())
local sess = sdir .. "/capcheck"
vim.fn.mkdir(sess, "p")
local f = io.open(sess .. "/audit.jsonl", "w")
for i = 1, 31 do
  local t = os.date("%Y-%m-%dT%H:%M:%S", os.time() + i)
  f:write(
    vim.json.encode({
      type = "approval_request",
      id = "r" .. i,
      tool = "bash",
      command = '{"command":"echo"}',
      reason = "resolved-" .. i,
      ts = t,
    }) .. "\n"
  )
  f:write(vim.json.encode({ type = "approval_result", id = "r" .. i, approved = true, ts = t }) .. "\n")
end
f:close()

-- Park one approval.
state.running[a] = {}
state.pending_approvals[a] = {
  id = "parked-1",
  tool = "bash",
  command = vim.json.encode({ command = "rm -rf /" }),
  reason = "parked-but-visible",
  ts = os.date("%Y-%m-%dT%H:%M:%S", os.time() - 1000),
}

guard.toggle()
local board = vim.api.nvim_get_current_buf()
local text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("parked-but-visible", 1, true), "parked approval dropped by cap: " .. text)

-- Only the newest 30 settled rows are read back (the oldest is capped away).
local n = 0
for _ in text:gmatch("resolved%-%d+") do
  n = n + 1
end
assert(n == 30, "expected 30 settled rows, got " .. n)

-- Appending to the log invalidates the cached snapshot even when its mtime
-- has the same second; a visible board must show the latest decision.
local append = io.open(sess .. "/audit.jsonl", "a")
local t = os.date("%Y-%m-%dT%H:%M:%S", os.time() + 40)
append:write(
  vim.json.encode({
    type = "approval_request",
    id = "r32",
    tool = "bash",
    command = "{}",
    reason = "new-decision",
    ts = t,
  }) .. "\n"
)
append:write(vim.json.encode({ type = "approval_result", id = "r32", approved = false, ts = t }) .. "\n")
append:close()
guard.touch()
text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("new-decision", 1, true), "append not reflected in cached board: " .. text)

guard.toggle() -- close
state.pending_approvals[a] = nil
state.running[a] = nil
print("OK guard cap")
