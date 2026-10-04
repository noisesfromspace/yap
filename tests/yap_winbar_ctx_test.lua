-- The context-fill chip is the "how full am I" gauge: the last turn's
-- prompt size against the model's context window, with a percentage so it
-- answers the question directly. Driven by the turn_end event, which lands
-- in harness.state.last_turn.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

local state = require("harness.state")
local buf = yap.new({ provider = "mock", model = "m1" })

-- No turn yet: the chip is absent.
assert(not yap.winbar(buf):match("󰊚"), "context chip shown before first turn")

-- A completed turn shows absolute fill + the percentage.
state.last_turn[buf] = { prompt = 5600, completion = 200, context_window = 250000 }
local wb = yap.winbar(buf)
assert(wb:match("5.6k/250k"), "context fill numbers missing: " .. wb)
assert(wb:match("2%%"), "context percentage missing: " .. wb)

-- A near-full window warns (amber), and the integer percentage reflects it.
state.last_turn[buf] = { prompt = 240000, completion = 200, context_window = 250000 }
wb = yap.winbar(buf)
assert(wb:match("96%%") and wb:match("YapNeeds"), "full context not flagged: " .. wb)

-- Sub-1% fills (big model, fresh session) keep a decimal instead of "0%".
state.last_turn[buf] = { prompt = 5000, completion = 200, context_window = 1000000 }
wb = yap.winbar(buf)
assert(wb:match("0.5%%"), "sub-1% fill not shown: " .. wb)

print("OK winbar_ctx")
