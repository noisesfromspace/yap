local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})

-- A completed turn shows a compact percentage and fixed-width graph,
-- without the raw token ratio or a context glyph.
local state = require("harness.state")
local buf = yap.new({ provider = "mock", model = "m1" })
state.last_turn[buf] = { prompt = 23000, completion = 200, context_window = 250000 }
local function winbar_at(cols)
  vim.cmd("vsplit")
  vim.api.nvim_win_set_width(0, cols)
  local bar = yap.winbar(buf)
  vim.cmd("close")
  return bar
end

state.live_usage[buf] = {
  prompt = 1500,
  completion = 42,
  context_prompt = 1500,
  context_window = 250000,
  cost = 0.00342,
}
local live_bar = winbar_at(80)
assert(live_bar:match("1.5k"), "live usage missing from winbar: " .. live_bar)
-- The cost detail yields so the model island keeps its place; a wider bar
-- brings it back (yap_winbar_resize_test pins that end of the ladder).
assert(not live_bar:match("%$0.00342"), "costs should yield before the model name: " .. live_bar)
assert(live_bar:find("GaugeEmpty", 1, true), "context meter missing from the winbar: " .. live_bar)
assert(not live_bar:find("Context", 1, true), "context meter should carry no label: " .. live_bar)
assert(not live_bar:find("󰃨", 1, true), "cache chip should hide when cache fields are absent: " .. live_bar)
state.live_usage[buf] = {
  prompt = 1200,
  completion = 42,
  context_prompt = 1500,
  cache_read = 300,
  cache_write = 0,
  context_window = 250000,
  cost = 0.00342,
}
live_bar = winbar_at(80)
assert(live_bar:find("󰃨", 1, true) and live_bar:match("20%%"), "turn cache-read percentage missing: " .. live_bar)

-- Cache label uses cumulative turn totals, not the latest step context.
state.live_usage[buf] = {
  prompt = 2400,
  completion = 42,
  context_prompt = 1500,
  cache_read = 600,
  cache_write = 0,
  context_window = 250000,
  cost = 0.00342,
}
live_bar = winbar_at(80)
assert(
  live_bar:find("󰃨", 1, true) and live_bar:match("20%%"),
  "cache percentage should use turn totals even when cumulative input exceeds last-step context: " .. live_bar
)

-- Cache writes count toward input denominator, but are not cache hits.
state.live_usage[buf] = {
  prompt = 1000,
  completion = 42,
  context_prompt = 900,
  cache_read = 200,
  cache_write = 800,
  context_window = 250000,
  cost = 0.00342,
}
live_bar = winbar_at(80)
assert(live_bar:find("󰃨", 1, true) and live_bar:match("10%%"), "cache writes should reduce read-hit percentage: " .. live_bar)
state.live_usage[buf] = nil

-- When they compete for space, the cache chip goes before the context meter.
state.live_usage[buf] = {
  prompt = 1200, completion = 42, context_prompt = 1500,
  cache_read = 300, cache_write = 0, context_window = 250000,
}
local saw_cache_yield = false
for cols = 80, 20, -1 do
  local narrow = winbar_at(cols)
  if not narrow:find("󰃨", 1, true) and narrow:find("GaugeEmpty", 1, true) then
    saw_cache_yield = true
    break
  end
end
assert(saw_cache_yield, "cache never yielded while context meter remained")
state.live_usage[buf] = nil

local function graph_width(bar)
  local width = 0
  for _, glyph in ipairs({ "", "", "", "", "", "" }) do
    local _, count = bar:gsub(glyph, "")
    width = width + count
  end
  return width
end

for _, case in ipairs({
  { prompt = 23000, context_window = 250000, pct = "9%%", hl = "YapIslandUprightGaugeLow" },
  { prompt = 200000, context_window = 250000, pct = "80%%", hl = "YapIslandUprightGaugeMid" },
  { prompt = 240000, context_window = 250000, pct = "96%%", hl = "YapIslandUprightGaugeHigh" },
  { prompt = 250000, context_window = 250000, pct = "100%%", hl = "YapIslandUprightGaugeHigh" },
}) do
  state.last_turn[buf] = case
  local wb = winbar_at(60)
  assert(not wb:find("󰊚", 1, true), "context glyph shown: " .. wb)
  assert(not wb:match("23k/250k"), "raw context sizes shown: " .. wb)
  assert(graph_width(wb) == 8, "context graph width changed: " .. wb)
  local rounded_full = math.floor(case.prompt / case.context_window * 8 + 0.5) == 8
  assert(
    wb:find("", 1, true) and wb:find(rounded_full and "" or "", 1, true),
    "rounded meter ends missing: " .. wb
  )
  assert(wb:match(case.hl), "wrong context graph band at " .. case.pct .. ": " .. wb)
  assert(not wb:match("Context"), "the meter must not be labelled: " .. wb)
end

-- The model name is this session's identity, so the meter is what goes when
-- the bar runs out of room; only a much narrower bar gives up the island.
state.last_turn[buf] = { prompt = 23000, context_window = 250000 }
local medium = winbar_at(25)
assert(medium:find("mock/m1", 1, true), "meter outlived the model name: " .. medium)
assert(not medium:find("GaugeEmpty", 1, true), "meter should yield before the model name: " .. medium)
assert(not winbar_at(12):find("mock/m1", 1, true), "model island survived a 12-column bar")

for _, group in ipairs({ "YapGaugeEmpty", "YapGaugeLow", "YapGaugeMid", "YapGaugeHigh" }) do
  assert(
    vim.api.nvim_get_hl(0, { name = group, link = false }).bg
      == vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false }).bg,
    group .. " should share the distinct gauge background"
  )
end

-- Usage numbers and the percentage must not inherit the dim Comment/WinBarNC
-- foreground. They should follow the model name even after a theme change.
vim.api.nvim_set_hl(0, "Keyword", { fg = 0xdddddd })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x333333 })
vim.api.nvim_exec_autocmds("ColorScheme", {})
local model_fg = vim.api.nvim_get_hl(0, { name = "YapCursiveModel", link = false }).fg
assert(model_fg == 0xdddddd, "theme change did not update model color")
for _, group in ipairs({ "YapUprightIdle", "YapIslandUprightCount" }) do
  assert(
    vim.api.nvim_get_hl(0, { name = group, link = false }).fg == model_fg,
    group .. " should use the model's readable foreground"
  )
end
state.last_turn[buf] = { prompt = 23000, context_window = 250000 }
vim.b[buf].yap_usage = { prompt = 1200, completion = 100, cost = 0.002 }
local bar = winbar_at(80)
assert(bar:find("%#YapIslandUprightCount#", 1, true), "usage text missing island foreground: " .. bar)
local right = assert(bar:match(".*%%=(.*)$"))
local displayed = vim.api.nvim_eval_statusline(right, { winid = 0, use_winbar = true, maxwidth = 200 }).str
assert(displayed:find("1.3k", 1, true), "counters missing from the right cluster: " .. displayed)
assert(
  select(2, displayed:gsub("", "")) == 2 and select(2, displayed:gsub("", "")) == 2,
  "counters and meter should be adjacent islands: " .. displayed
)
-- The model name outlives the meter: where the meter no longer fits, the
-- island still identifies the session.
local crowded = winbar_at(60)
assert(crowded:find("mock/m1", 1, true), "model island dropped while counters fit: " .. crowded)
assert(not crowded:find("GaugeEmpty", 1, true), "meter should yield before the model name: " .. crowded)

print("OK winbar_ctx")
