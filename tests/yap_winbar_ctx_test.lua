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

-- With room to spare, the graph grows to use the otherwise-empty winbar
-- width. Its band color is still driven by context fill, not graph width.
state.last_turn[buf] = { prompt = 200000, completion = 200, context_window = 250000 }
vim.b[buf].yap_usage = nil
vim.b[buf].yap_session_usage = nil
local function winbar_at(cols)
  vim.cmd("vsplit")
  vim.api.nvim_win_set_width(0, cols)
  local bar = yap.winbar(buf)
  local cols = vim.api.nvim_win_get_width(0)
  vim.cmd("close")
  return bar, cols
end
local narrow = winbar_at(30)
local wide, wide_cols = winbar_at(60)
local function graph_width(bar)
  local _, filled = bar:gsub("█", "")
  local _, track = bar:gsub("░", "")
  return filled + track
end
assert(graph_width(wide) > graph_width(narrow), "context graph did not expand with available width")
assert(wide:match("YapGaugeMid"), "expanded graph lost its context-fill color")
-- `%=` is an alignment operator, not literal content; the expanded graph
-- should consume all available width rather than leave an artificial gap.
local literals = wide:gsub("%%#.-#", ""):gsub("%%[%*=]", ""):gsub("%%%%", "%%")
assert(vim.fn.strdisplaywidth(literals) == wide_cols, "expanded graph left winbar width unused")

print("OK winbar_ctx")
