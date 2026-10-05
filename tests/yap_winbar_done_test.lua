local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local state = require("harness.state")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local buf = yap.new({ provider = "mock", model = "m1" })
local function left()
  return assert(yap.winbar(buf):match("^(.-)%%="))
end
assert(not left():find("", 1, true), "fresh chat is not done")
state.awaiting[buf] = true
assert(left():find("%#YapDone#", 1, true), "waiting chat needs a verified icon")
assert(vim.api.nvim_get_hl(0, { name = "YapDone" }).link == "DiagnosticOk", "done icon should be theme colored")
state.running[buf] = {}
assert(not left():find("", 1, true) and left():find("%#YapBusyIcon#", 1, true),
  "spinner should replace verified icon while generating")
state.running[buf] = nil
state.errors[buf] = "failed"
assert(not left():find("", 1, true), "a failed turn is not done")
state.errors[buf] = nil
state.awaiting[buf] = nil
assert(not left():find("", 1, true), "sending clears done state")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @assistant", "", "Done", "", "# @user", "" })
require("harness.winbar").seed_awaiting(buf)
assert(left():find("%#YapDone#", 1, true), "reopened awaiting chat should show verified icon")
state.awaiting[buf] = nil
print("OK winbar_done")
