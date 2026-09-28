local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime! plugin/pitel.lua")
local pitel = require("harness")
pitel.setup({ bin = ROOT .. "/pitel", models = { "mock/m1", "mock/m2", "other/o1" } })
local buf = pitel.new({ provider = "mock", model = "m1" })
assert(pitel.winbar(buf):match("mock/m1"), "initial combo")
-- direct argument
pitel.change_model("other/o1")
assert(vim.b[buf].pitel_provider == "other" and vim.b[buf].pitel_model == "o1", "vars not set")
assert(pitel.winbar(buf):match("other/o1"), "winbar not updated")
-- command plumbing
vim.cmd("PitelChangeModel mock/m2")
assert(vim.b[buf].pitel_model == "m2", "command failed")
-- invalid argument keeps the old combo
pitel.change_model("garbage")
assert(vim.b[buf].pitel_model == "m2", "invalid combo clobbered state")
print("OK model")
