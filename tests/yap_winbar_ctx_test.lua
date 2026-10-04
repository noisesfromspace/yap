local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

-- The context window is retained in turn state, but the winbar shows no
-- context-size chip or gauge. This should remain true after a completed turn.
local state = require("harness.state")
local buf = yap.new({ provider = "mock", model = "m1" })
state.last_turn[buf] = { prompt = 23000, completion = 200, context_window = 250000 }
local wb = yap.winbar(buf)
assert(not wb:find("󰊚", 1, true), "context glyph shown: " .. wb)
assert(not wb:match("23k/250k"), "context sizes shown: " .. wb)
assert(not wb:match("█") and not wb:match("░"), "context gauge shown: " .. wb)

print("OK winbar_ctx")
