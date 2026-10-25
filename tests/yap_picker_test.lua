local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" }) -- backend discovery only
local buf = yap.new({ provider = "alpha", model = "m1" })
local captured
vim.ui.select = function(items, _, cb)
  captured = items
  cb(items[2])
end
yap.change_model()
local ok = vim.wait(5000, function()
  return captured ~= nil
end, 100)
assert(ok, "picker never opened")
assert(vim.deep_equal(captured, { "alpha/m1", "alpha/m2" }), vim.inspect(captured))
assert(vim.b[buf].yap_model == "m2", "selection not applied")
-- A setup-supplied picker list cannot bypass backend discovery.
local ok_override = pcall(yap.setup, { models = { "x/y" } })
assert(not ok_override, "models override should be rejected")
print("OK picker")
