local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "do some work" })
yap.send(buf)
assert(vim.wait(10000, function() return yap.is_running(buf) end, 50), "turn did not start")
-- Let the serve backend set up its update channel and start the slow tool
-- (sleep 1.5s), so the switch lands mid-turn at the next model boundary.
vim.wait(400)

yap.change_model("mock/m2")

assert(vim.wait(15000, function() return not yap.is_running(buf) end, 100), "turn did not complete")
vim.wait(200)

local t = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(t:find('<!-- yap:model {"from":"mock/m1","to":"mock/m2"} -->', 1, true), "model marker missing:\n" .. t)
assert(t:find("answer from m2", 1, true), "switch did not reach the model:\n" .. t)
assert(not t:find("answer from m1", 1, true), "still answered with the old model:\n" .. t)

print("OK model switch")
