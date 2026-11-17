local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })
local icons = require("harness").config.icons

local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "do some work" })
yap.send(buf)
assert(vim.wait(10000, function() return yap.is_running(buf) end, 50), "turn did not start")
-- Let the serve backend start the slow tool (sleep 1.5s) so the clear queues
-- mid-turn rather than running immediately.
vim.wait(400)

-- :YapClear while running queues instead of refusing: the winbar advertises
-- it with the broom icon while the turn keeps running.
yap.clear(buf, 0)
assert(yap.winbar(buf):find(icons.clear, 1, true), "queued clear icon missing: " .. yap.winbar(buf))

assert(vim.wait(15000, function() return not yap.is_running(buf) end, 100), "turn did not complete")
vim.wait(200)

assert(not yap.winbar(buf):find(icons.clear, 1, true), "queued clear icon lingered after the turn: " .. yap.winbar(buf))

local t = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(not t:find("tool%-done", 1, true), "tool output was not cleared after the queued clear:\n" .. t)
assert(t:find("[output cleared", 1, true), "no placeholder after the queued clear:\n" .. t)

print("OK queued clear")
