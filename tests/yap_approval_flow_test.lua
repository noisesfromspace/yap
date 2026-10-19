-- A parked approval is a first-class state, not a modal: the session's own
-- winbar shows the shield, other sessions' rollup counts it as "approval"
-- (not running), and the guard board's single list shows every parked
-- approval (above the static rules). Answering clears the approval; closing
-- the board defers (never denies).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local icons = require("harness").config.icons
local state = require("harness.state")
local guard = require("harness.guard")

local a = yap.new({ provider = "mock", model = "m1" })
local b = yap.new({ provider = "mock", model = "m1" })

local function park(buf, id, tool, command, reason)
  state.running[buf] = {}
  state.pending_approvals[buf] = {
    id = id,
    tool = tool,
    command = command,
    reason = reason,
    ts = os.date("%Y-%m-%dT%H:%M:%S"),
  }
end
park(a, "approval-1", "bash", vim.json.encode({ command = "rm -rf /" }), "recursive or forced deletion")

-- `a`'s own bar shows the shield in the gutter, not the busy spinner.
local bar_a = yap.winbar(a)
assert(bar_a:find(icons.approval, 1, true), "parked session missing shield: " .. bar_a)
assert(not bar_a:find("YapBusySpin", 1, true), "parked session still shows the spinner")

-- `b`'s rollup counts `a` as approval, never as running.
local bar_b = yap.winbar(b)
assert(bar_b:find(icons.approval .. "1", 1, true), "rollup missing approval count: " .. bar_b)
assert(not bar_b:match(icons.running .. "%d"), "parked session counted as running: " .. bar_b)

park(b, "approval-2", "ssh", "rm -rf /", "remote command execution")

-- The board is one durable buffer listing both parked approvals and the
-- compiled-in static rules below them.
guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(board) == "yap://guard", "guard board did not open: " .. vim.api.nvim_buf_get_name(board))
local text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("recursive or forced deletion", 1, true), "board missing first reason")
assert(text:find("remote command execution", 1, true), "board missing second reason")
assert(text:find("sudo", 1, true), "board missing the static rules list")
assert(not vim.bo[board].modifiable, "guard board should be read-only")

-- Closing the board defers: both approvals stay parked.
guard.toggle()
assert(state.pending_approvals[a] ~= nil and state.pending_approvals[b] ~= nil, "closing the board answered an approval")

-- Run answers one approval; the other stays parked.
yap.answer_approval(a, true)
assert(state.pending_approvals[a] == nil, "Run did not clear the approval")
assert(state.pending_approvals[b] ~= nil, "Run cleared the wrong approval")

state.running[a] = nil
state.running[b] = nil
state.pending_approvals[a] = nil
state.pending_approvals[b] = nil
print("OK approval flow")
