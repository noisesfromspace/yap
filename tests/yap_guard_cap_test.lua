-- The guard board caps its settled-history list (30 rows), but a parked
-- approval is live state and always shown first: a backlog of settled rows
-- must never hide a parked approval. History is recorded in memory for this
-- Neovim process, so the cap applies to rows accumulated since startup.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})
local state = require("harness.state")
local guard = require("harness.ui.guard")

local a = yap.new({ provider = "mock", model = "m1" })

-- 31 settled approvals recorded this Neovim process.
for i = 1, 31 do
  guard.record_result(a, {
    id = "r" .. i,
    tool = "bash",
    command = '{"command":"echo"}',
    reason = "resolved-" .. i,
  }, true)
end

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

-- Only the newest 30 settled rows are listed (the oldest is capped away).
local n = 0
for _ in text:gmatch("resolved%-%d+") do
  n = n + 1
end
assert(n == 30, "expected 30 settled rows, got " .. n)

-- A settled row recorded after the board is open shows on the next touch.
guard.record_result(a, {
  id = "r32",
  tool = "bash",
  command = "{}",
  reason = "new-decision",
}, false)
guard.touch()
text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("new-decision", 1, true), "new decision not reflected in board: " .. text)

guard.toggle() -- close
state.pending_approvals[a] = nil
state.running[a] = nil
print("OK guard cap")
