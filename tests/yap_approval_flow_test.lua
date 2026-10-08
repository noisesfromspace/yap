-- A parked approval is a first-class state, not a modal: the session's own
-- winbar shows the shield, other sessions' rollup counts it as "approval"
-- (not running), and :YapApproval with several sessions parked at once
-- first asks which approval to answer.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local icons = require("harness").config.icons
local state = require("harness.state")

local a = yap.new({ provider = "mock", model = "m1" })
local b = yap.new({ provider = "mock", model = "m1" })

-- Park an approval on `a` (the turn is still running: the backend waits).
state.running[a] = {}
state.pending_approvals[a] = {
  id = "approval-1",
  tool = "bash",
  command = vim.json.encode({ command = "rm -rf /" }),
  reason = "recursive or forced deletion",
}

-- `a`'s own bar shows the shield in the gutter, not the busy spinner.
local bar_a = yap.winbar(a)
assert(bar_a:find(icons.approval, 1, true), "parked session missing shield: " .. bar_a)
assert(not bar_a:find("YapBusySpin", 1, true), "parked session still shows the spinner")

-- `b`'s rollup counts `a` as approval, never as running.
local bar_b = yap.winbar(b)
assert(bar_b:find(icons.approval .. "1", 1, true), "rollup missing approval count: " .. bar_b)
assert(not bar_b:match(icons.running .. "%d"), "parked session counted as running: " .. bar_b)

-- A second parked session; from a non-session buffer :YapApproval must ask
-- which approval to answer before Run/Deny/Inspect.
state.running[b] = {}
state.pending_approvals[b] = { id = "approval-2", tool = "ssh", command = "rm -rf /", reason = "requires approval" }
local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(other)

local picks = {}
local chooser_opts
local old_select = vim.ui.select
vim.ui.select = function(items, opts, cb)
  picks[#picks + 1] = vim.deepcopy(items)
  if type(items[1]) == "table" then
    chooser_opts = opts
    cb(items[2])
  else
    cb(nil) -- defer: Esc/Ctrl-C on the action picker
  end
end
yap.approval()
vim.ui.select = old_select

assert(#picks == 2, "expected chooser then action picker, got " .. #picks)
assert(#picks[1] == 2, "chooser should list both parked approvals")
assert(vim.deep_equal(picks[2], { "Run", "Deny", "Inspect" }), "action picker lacks Run/Deny/Inspect")
assert(chooser_opts and chooser_opts.preview_item, "chooser missing preview")
local preview = chooser_opts.preview_item(picks[1][2])
assert(preview and vim.api.nvim_buf_is_valid(preview.buf), "approval chooser preview missing")
vim.api.nvim_buf_delete(preview.buf, { force = true })

-- Deferring the action picker left both approvals pending.
assert(state.pending_approvals[a] ~= nil and state.pending_approvals[b] ~= nil, "defer answered an approval")
vim.api.nvim_buf_delete(other, { force = true })
-- Undo the fake running state so the session buffers' BufUnload stop() has
-- nothing to kill.
state.running[a] = nil
state.running[b] = nil
state.pending_approvals[a] = nil
state.pending_approvals[b] = nil
print("OK approval flow")
