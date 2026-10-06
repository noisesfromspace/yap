local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local state = require("harness.state")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local icons = require("harness").config.icons
local buf = yap.new({ provider = "mock", model = "m1" })
local function left()
  return assert(yap.winbar(buf):match("^(.-)%%="))
end
assert(left():find("%#YapIdle#" .. icons.idle, 1, true), "fresh chat needs an idle icon")
state.awaiting[buf] = true
assert(left():find("%#YapNeeds#" .. icons.waiting, 1, true), "waiting chat needs a waiting icon")
state.running[buf] = {}
assert(not left():find(icons.waiting, 1, true) and left():find("%#YapBusy", 1, true),
  "spinner should replace the waiting icon while generating")
state.running[buf] = nil
state.errors[buf] = "failed"
assert(left():find("%#YapError#" .. icons.error, 1, true), "a failed turn needs an error icon")
state.errors[buf] = nil
state.stopped[buf] = true
assert(left():find("%#YapNeeds#" .. icons.stopped, 1, true), "a stopped turn needs a stopped icon")
state.stopped[buf] = nil
state.awaiting[buf] = nil
assert(left():find("%#YapIdle#" .. icons.idle, 1, true), "clearing state returns to idle")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @assistant", "", "Done", "", "# @user", "" })
require("harness.winbar").seed_awaiting(buf)
assert(left():find("%#YapNeeds#" .. icons.waiting, 1, true), "reopened awaiting chat should show a waiting icon")
state.awaiting[buf] = nil
print("OK winbar_done")
