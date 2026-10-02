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

-- Wide: everything is present.
local wb = winbar_at(80)
assert(wb:match("mock/m1"), "wide winbar missing model: " .. wb)
assert(wb:match("1.5k in · 42 out"), "wide winbar missing full tokens: " .. wb)
assert(wb:match("%$0.00342"), "wide winbar missing buffer cost: " .. wb)
assert(wb:match("session %$0.51"), "wide winbar missing session cost: " .. wb)
assert(wb:match("○ idle"), "wide winbar missing state: " .. wb)

-- Narrow: state glyph (busy is duplicated on the left) and model/fold go
-- first; tokens collapse to in→out; both prices survive.
wb = winbar_at(40)
assert(not wb:match("○ idle"), "narrow winbar kept the state glyph: " .. wb)
assert(not wb:match("mock/m1"), "narrow winbar kept the model: " .. wb)
assert(wb:match("1.5k→42"), "narrow winbar missing compact tokens: " .. wb)
assert(wb:match("%$0.00342"), "narrow winbar missing buffer cost: " .. wb)
assert(wb:match("Σ%$0.51"), "narrow winbar missing session total: " .. wb)

-- Very narrow: only the two prices remain.
wb = winbar_at(25)
assert(not wb:match("1.5k"), "tiny winbar kept tokens: " .. wb)
assert(wb:match("%$0.00342"), "tiny winbar missing buffer cost: " .. wb)
assert(wb:match("Σ%$0.51"), "tiny winbar missing session total: " .. wb)
print("OK winbar_resize")
