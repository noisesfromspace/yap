local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local path = vim.fn.stdpath("cache") .. "/yap/models"
vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
vim.fn.writefile({ "alpha/old" }, path)

local system = vim.system
local callbacks = {}
vim.system = function(_, _, cb)
  table.insert(callbacks, cb)
end

local yap = require("harness")
yap.setup({ bin = "test-yap" })
assert(#callbacks == 1, "setup should refresh models in the background")
local buf = yap.new({ provider = "alpha", model = "old" })
local picked = {}
vim.ui.select = function(items, _, cb)
  table.insert(picked, vim.deepcopy(items))
  cb(items[1])
end
yap.change_model()
assert(vim.deep_equal(picked[1], { "alpha/old" }), "cached picker should open before refresh completes")
callbacks[1]({ code = 0, stdout = "alpha/new\nbeta/new\n", stderr = "" })
assert(vim.wait(1000, function() return vim.deep_equal(vim.fn.readfile(path), { "alpha/new", "beta/new" }) end))
assert(#picked == 1, "refresh should not reopen the picker")
yap.change_model()
assert(vim.deep_equal(picked[2], { "alpha/new", "beta/new" }), "next picker should use refreshed list")

yap.setup({ bin = "test-yap" })
assert(#callbacks == 2, "setup should retry discovery")
callbacks[2]({ code = 1, stdout = "", stderr = "offline" })
assert(vim.wait(1000, function() return #callbacks == 2 end))
yap.change_model()
assert(vim.deep_equal(picked[3], { "alpha/new", "beta/new" }), "failure should keep last good list")
assert(vim.deep_equal(vim.fn.readfile(path), { "alpha/new", "beta/new" }), "failure should keep disk cache")
vim.system = system
assert(vim.b[buf].yap_provider == "alpha")
print("OK model cache")
