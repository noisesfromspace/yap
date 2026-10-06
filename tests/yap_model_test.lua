local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime! plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", models = { "mock/m1", "mock/m2", "other/o1" } })
local buf = yap.new({ provider = "mock", model = "m1" })
assert(yap.winbar(buf):match("mock/m1"), "initial combo")
-- direct argument
local notices = {}
local notify = vim.notify
vim.notify = function(msg)
  notices[#notices + 1] = msg
end
yap.change_model("other/o1")
vim.notify = notify
assert(#notices == 0, "successful model change should not notify: " .. table.concat(notices, " | "))
assert(vim.b[buf].yap_provider == "other" and vim.b[buf].yap_model == "o1", "vars not set")
assert(yap.winbar(buf):match("other/o1"), "winbar not updated")
-- command plumbing
local command_notices = {}
vim.notify = function(msg)
  command_notices[#command_notices + 1] = msg
end
vim.cmd("YapChangeModel mock/m2")
vim.notify = notify
assert(#command_notices == 0, "model command should stay quiet: " .. table.concat(command_notices, " | "))
assert(vim.b[buf].yap_model == "m2", "command failed")
-- invalid argument keeps the old combo
yap.change_model("garbage")
assert(vim.b[buf].yap_model == "m2", "invalid combo clobbered state")
print("OK model")
