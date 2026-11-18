local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })

-- A completed turn shows a compact, icon-led percentage (`󰊚 9%`) instead of
-- a graph or a raw token ratio. The cache read-hit rate is a warning, not a
-- chip: it appears only while the rate is unusually low.
local state = require("harness.state")
local icons = yap.config.icons
local buf = yap.new({ provider = "mock", model = "m1" })

local function winbar_at(cols)
  vim.cmd("vsplit")
  vim.api.nvim_win_set_width(0, cols)
  local bar = yap.winbar(buf)
  vim.cmd("close")
  return bar
end
local function plain(bar)
  return (bar:gsub("%%#.-#", ""):gsub("%%%*", ""):gsub("%%%%", "%%"))
end

-- ─── Context is a percentage ──────────────────────────────────────────────
state.live_usage[buf] = {
  prompt = 1500,
  completion = 42,
  context_prompt = 1500,
  context_window = 250000,
  cost = 0.00342,
}
local bar = winbar_at(80)
assert(plain(bar):find(icons.total .. " 1.5k", 1, true), "all-time usage missing: " .. plain(bar))
assert(not plain(bar):find(icons.since, 1, true), "duplicate spend should hide the since-open chip: " .. plain(bar))
assert(plain(bar):find(icons.context .. " 1%", 1, true), "context percentage missing: " .. plain(bar))
assert(not plain(bar):find("23k/250k", 1, true), "raw context sizes shown: " .. plain(bar))
assert(not plain(bar):find("Context", 1, true), "context should carry no long label: " .. plain(bar))
assert(not plain(bar):find(icons.cache, 1, true), "cache warning should hide when absent: " .. plain(bar))
state.live_usage[buf] = nil

-- ─── Context bands ────────────────────────────────────────────────────────
for _, case in ipairs({
  { prompt = 23000, context_window = 250000, pct = icons.context .. " 9%", hl = "YapIslandUprightGaugeLow" },
  { prompt = 200000, context_window = 250000, pct = icons.context .. " 80%", hl = "YapIslandUprightGaugeMid" },
  { prompt = 240000, context_window = 250000, pct = icons.context .. " 96%", hl = "YapIslandUprightGaugeHigh" },
  { prompt = 250000, context_window = 250000, pct = icons.context .. " 100%", hl = "YapIslandUprightGaugeHigh" },
}) do
  state.last_turn[buf] = case
  local wb = winbar_at(60)
  assert(plain(wb):find(case.pct, 1, true), "wrong context percentage: " .. plain(wb))
  assert(wb:find("%#" .. case.hl .. "#", 1, true), "wrong context band at " .. case.pct .. ": " .. wb)
end
state.last_turn[buf] = nil

-- ─── Cache is a warning, not a chip ───────────────────────────────────────
-- A low read-hit rate shows in the warning color; a healthy rate and absent
-- data stay invisible.
state.live_usage[buf] = {
  prompt = 1200,
  completion = 42,
  context_prompt = 1500,
  cache_read = 300,
  cache_write = 0,
  context_window = 250000,
}
bar = winbar_at(80)
assert(plain(bar):find(icons.cache .. " 20%", 1, true), "low cache warning missing: " .. plain(bar))
assert(bar:find("%#YapIslandUprightNeeds#", 1, true), "cache warning should use the warning color: " .. bar)

state.live_usage[buf] = {
  prompt = 200,
  completion = 42,
  context_prompt = 1500,
  cache_read = 800,
  cache_write = 0,
  context_window = 250000,
}
bar = winbar_at(80)
assert(not plain(bar):find(icons.cache, 1, true), "healthy cache should stay invisible: " .. plain(bar))

-- Cache uses cumulative turn totals, not the latest step context.
state.live_usage[buf] = {
  prompt = 2400,
  completion = 42,
  context_prompt = 1500,
  cache_read = 600,
  cache_write = 0,
  context_window = 250000,
}
bar = winbar_at(80)
assert(plain(bar):find(icons.cache .. " 20%", 1, true), "cache should use turn totals: " .. plain(bar))

-- Cache writes count toward the input denominator, but are not hits.
state.live_usage[buf] = {
  prompt = 1000,
  completion = 42,
  context_prompt = 900,
  cache_read = 200,
  cache_write = 800,
  context_window = 250000,
}
bar = winbar_at(80)
assert(plain(bar):find(icons.cache .. " 10%", 1, true), "cache writes should reduce the read-hit rate: " .. plain(bar))
state.live_usage[buf] = nil

-- ─── The model outlives the context reading ───────────────────────────────
state.last_turn[buf] = { prompt = 23000, context_window = 250000 }
local medium = winbar_at(25)
assert(medium:find(" m1 ", 1, true), "context outlived the model: " .. medium)
assert(not plain(medium):find(icons.context, 1, true), "context should yield before the model: " .. medium)
assert(winbar_at(12):find(" m1 ", 1, true), "model island should survive a 12-column bar")
state.last_turn[buf] = nil

-- ─── Usage numbers and the cache warning follow the theme ─────────────────
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

print("OK winbar_ctx")
