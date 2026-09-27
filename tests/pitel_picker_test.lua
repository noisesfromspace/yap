local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("pitel")
pitel.setup({ bin = ROOT .. "/pitel" }) -- no models list
local buf = pitel.new({ provider = "alpha", model = "m1" })
local captured
vim.ui.select = function(items, _, cb)
  captured = items
  cb(items[2])
end
pitel.change_model()
local ok = vim.wait(5000, function() return captured ~= nil end, 100)
assert(ok, "picker never opened")
assert(vim.deep_equal(captured, { "alpha/m1", "alpha/m2" }), vim.inspect(captured))
assert(vim.b[buf].pitel_model == "m2", "selection not applied")
-- configured list still wins and skips the binary
pitel.setup({ bin = "/definitely/not/here", models = { "x/y" } })
captured = nil
pitel.change_model()
assert(captured and captured[1] == "x/y", "configured models not used")
print("OK picker")
