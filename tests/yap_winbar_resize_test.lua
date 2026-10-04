local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

local buf = yap.new({ provider = "mock", model = "m1" })
-- Simulate a completed session without a network round-trip: usage lives
-- in per-buffer state and the session total is what adopt() seeds.
vim.b[buf].yap_usage = { prompt = 1500, completion = 42, cost = 0.00342 }
vim.b[buf].yap_session_usage = { prompt = 999, completion = 99, cost = 0.51 }

-- render_winbar measures the CURRENT window, so give it one of a known
-- width for each assertion: split, resize the new window, read the bar,
-- then close back to the original.
local function winbar_at(cols)
  vim.cmd("vsplit")
  vim.api.nvim_win_set_width(0, cols)
  local wb = yap.winbar(buf)
  vim.cmd("close")
  return wb
end

-- Wide: everything is present — model, both chips (tokens + cost). No
-- state glyph: idle/awaiting are silent, only errors get one.
local wb = winbar_at(80)
assert(wb:match("mock/m1"), "wide winbar missing model: " .. wb)
assert(wb:match("1.5k") and wb:match("1.1k"), "wide winbar missing chips: " .. wb)
assert(wb:match("%$0.00342") and wb:match("%$0.51"), "wide winbar missing costs: " .. wb)
assert(wb:match("󰅐") and wb:match("󰆼"), "wide winbar missing icons: " .. wb)
assert(not wb:match("idle") and not wb:match("waiting"), "wide winbar has a state glyph: " .. wb)

-- Narrower: model/fold go first; chips keep tokens + cost.
wb = winbar_at(40)
assert(not wb:match("mock/m1"), "40-col winbar kept the model: " .. wb)
assert(wb:match("1.5k") and wb:match("1.1k"), "40-col winbar missing tokens: " .. wb)
assert(wb:match("%$0.00342") and wb:match("%$0.51"), "40-col winbar missing costs: " .. wb)

-- Narrow: costs drop, tokens survive.
wb = winbar_at(25)
assert(wb:match("1.5k") and wb:match("1.1k"), "narrow winbar missing tokens: " .. wb)
assert(not wb:match("%$"), "narrow winbar kept costs: " .. wb)

-- Very narrow: only the two prices remain.
wb = winbar_at(12)
assert(not wb:match("1.5k") and not wb:match("1.1k"), "tiny winbar kept tokens: " .. wb)
assert(wb:match("%$0.00342") and wb:match("%$0.51"), "tiny winbar missing prices: " .. wb)
print("OK winbar_resize")
