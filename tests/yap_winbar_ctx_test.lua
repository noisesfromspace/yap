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

-- A completed turn shows absolute fill + the percentage and the gauge.
state.last_turn[buf] = { prompt = 5600, completion = 200, context_window = 250000 }
local wb = yap.winbar(buf)
assert(wb:match("5.6k/250k"), "context fill numbers missing: " .. wb)
assert(wb:match("2%%"), "context percentage missing: " .. wb)
assert(wb:match("░") and wb:match("YapGaugeLow"), "context gauge missing/low: " .. wb)

-- A mid-band fill (70–90%) turns the gauge amber.
state.last_turn[buf] = { prompt = 200000, completion = 200, context_window = 250000 }
wb = yap.winbar(buf)
assert(wb:match("80%%") and wb:match("YapGaugeMid"), "mid context not amber: " .. wb)

-- A near-full window turns the gauge red, and the integer percentage reflects it.
state.last_turn[buf] = { prompt = 240000, completion = 200, context_window = 250000 }
wb = yap.winbar(buf)
assert(wb:match("96%%") and wb:match("YapGaugeHigh"), "full context not flagged: " .. wb)

-- Sub-1% fills (big model, fresh session) keep a decimal instead of "0%".
state.last_turn[buf] = { prompt = 5000, completion = 200, context_window = 1000000 }
wb = yap.winbar(buf)
assert(wb:match("0.5%%"), "sub-1% fill not shown: " .. wb)

-- The context graph stays eight cells wide at every window size; spare
-- space remains between the left and right winbar sections.
state.last_turn[buf] = { prompt = 200000, completion = 200, context_window = 250000 }
vim.b[buf].yap_usage = nil
vim.b[buf].yap_session_usage = nil
local function winbar_at(cols)
  vim.cmd("vsplit")
  vim.api.nvim_win_set_width(0, cols)
  local bar = yap.winbar(buf)
  vim.cmd("close")
  return bar
end
local narrow = winbar_at(30)
local wide = winbar_at(60)
local function graph_width(bar)
  local _, filled = bar:gsub("█", "")
  local _, track = bar:gsub("░", "")
  local partial = 0
  for _, glyph in ipairs({ "▏", "▎", "▍", "▌", "▋", "▊", "▉" }) do
    local _, count = bar:gsub(glyph, "")
    partial = partial + count
  end
  return filled + track + partial
end
assert(graph_width(narrow) == 8, "narrow context gauge is not fixed at 8 cells")
assert(graph_width(wide) == 8, "wide context gauge expanded beyond 8 cells")
assert(wide:match("YapGaugeMid"), "context gauge lost its fill color")

print("OK winbar_ctx")
