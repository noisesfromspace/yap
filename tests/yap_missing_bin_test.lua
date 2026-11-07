local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local notices = {}
local original = vim.notify
vim.notify = function(msg)
  notices[#notices + 1] = msg
end
local bad = vim.fn.tempname() .. "/missing-yap"
yap.setup({ bin = bad, model_groups = { agent = "mock/m1", flash = "" } })
assert(#notices == 0, "setup warned before a managed session needed Yap")
local first = yap.new()
assert(#notices == 1 and notices[1]:find(bad, 1, true), "missing binary warning not actionable")
local second = yap.new()
assert(#notices == 1, "warning repeated for another session")
assert(yap.send(second) == false and #notices == 1, "send without a binary should be blocked without spamming")
yap.config.bin = ROOT .. "/yap"
assert(require("harness.client.lsp").bin_available(), "installing the binary did not recover")
yap.config.bin = bad
require("harness.client.lsp").warn_missing_bin()
assert(#notices == 2, "missing binary warning did not reset after recovery")
vim.notify = original
print("OK missing binary warning and recovery")
