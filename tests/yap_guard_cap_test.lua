-- The guard board caps its settled (resolved) history, but a parked approval
-- is the one actionable row (r/x act on it): 31 newer resolved rows must
-- never push a parked approval off the Guard section.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local state = require("harness.state")
local paths = require("harness.path")
local guard = require("harness.guard")

local a = yap.new({ provider = "mock", model = "m1" })

-- 31 resolved approvals, all newer than the parked one, in one audit log.
local sdir = paths.session_dir(vim.fn.getcwd())
local sess = sdir .. "/capcheck"
vim.fs.mkdir(sess, { parents = true })
local f = io.open(sess .. "/audit.jsonl", "w")
for i = 1, 31 do
  local ts = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + i)
  f:write(vim.json.encode({ type = "approval_request", id = "r" .. i, tool = "bash", command = '{"command":"echo"}', reason = "resolved-" .. i, ts = ts }) .. "\n")
  f:write(vim.json.encode({ type = "approval_result", id = "r" .. i, approved = true, ts = ts }) .. "\n")
end
f:close()

-- Park one approval, older than every resolved row, so the old cap would
-- have dropped it.
state.running[a] = {}
state.pending_approvals[a] = {
  id = "parked-1",
  tool = "bash",
  command = vim.json.encode({ command = "rm -rf /" }),
  reason = "parked-but-visible",
  ts = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 1000),
}

guard.toggle()
local board = vim.api.nvim_get_current_buf()
local text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("parked-but-visible", 1, true), "parked approval dropped by cap: " .. text)
guard.toggle()

state.pending_approvals[a] = nil
state.running[a] = nil
print("OK guard cap")
