local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

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

local function graph_width(bar)
  local _, full = bar:gsub("█", "")
  local _, empty = bar:gsub("░", "")
  local partial = 0
  for _, glyph in ipairs({ "▏", "▎", "▍", "▌", "▋", "▊", "▉" }) do
    local _, count = bar:gsub(glyph, "")
    partial = partial + count
  end
  return full + empty + partial
end

for _, case in ipairs({
  { prompt = 23000, context_window = 250000, pct = "9%%", hl = "YapIslandUprightGaugeLow" },
  { prompt = 200000, context_window = 250000, pct = "80%%", hl = "YapIslandUprightGaugeMid" },
  { prompt = 240000, context_window = 250000, pct = "96%%", hl = "YapIslandUprightGaugeHigh" },
  { prompt = 250000, context_window = 250000, pct = "100%%", hl = "YapIslandUprightGaugeHigh" },
}) do
  state.last_turn[buf] = case
  for _, width in ipairs({ 60, 12 }) do
    local wb = winbar_at(width)
    assert(not wb:find("󰊚", 1, true), "context glyph shown: " .. wb)
    assert(not wb:match("23k/250k"), "raw context sizes shown: " .. wb)
    assert(graph_width(wb) == 8, "context graph width changed at " .. width .. " cols: " .. wb)
    assert(wb:match(case.hl), "wrong context graph band at " .. case.pct .. ": " .. wb)
    assert(wb:find("%#YapIslandUprightGaugeLabel#", 1, true) or not wb:match("%d+%%"),
      "context percentage should use the gauge surface: " .. wb)
    if width > 12 then
      assert(wb:match(case.pct), "context percentage missing: " .. wb)
    else
      assert(not wb:match("%d+%%"), "narrow layout should drop the percentage: " .. wb)
    end
  end
end

for _, group in ipairs({ "YapGaugeEmpty", "YapGaugeLabel", "YapGaugeLow", "YapGaugeMid", "YapGaugeHigh" }) do
  assert(vim.api.nvim_get_hl(0, { name = group, link = false }).bg
      == vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false }).bg,
    group .. " should share the distinct gauge background")
end

-- Usage numbers and the percentage must not inherit the dim Comment/WinBarNC
-- foreground. They should follow the model name even after a theme change.
vim.api.nvim_set_hl(0, "Keyword", { fg = 0xdddddd })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x333333 })
vim.api.nvim_exec_autocmds("ColorScheme", {})
local model_fg = vim.api.nvim_get_hl(0, { name = "YapCursiveModel", link = false }).fg
assert(model_fg == 0xdddddd, "theme change did not update model color")
for _, group in ipairs({ "YapUprightIdle", "YapIslandUprightCount", "YapGaugeLabel", "YapIslandUprightGaugeLabel" }) do
  assert(vim.api.nvim_get_hl(0, { name = group, link = false }).fg == model_fg,
    group .. " should use the model's readable foreground")
end
state.last_turn[buf] = { prompt = 23000, context_window = 250000 }
vim.b[buf].yap_usage = { prompt = 1200, completion = 100, cost = 0.002 }
local bar = winbar_at(40)
assert(bar:find("%#YapIslandUprightCount#", 1, true), "usage text missing island foreground: " .. bar)
assert(bar:find("%#YapIslandUprightGaugeLabel#", 1, true), "gauge label missing island foreground: " .. bar)
local right = assert(bar:match("%%=(.*)$"))
local displayed = vim.api.nvim_eval_statusline(right, { winid = 0, use_winbar = true, maxwidth = 200 }).str
assert(displayed:find(" 󰅐 1.3k · $0.002   ", 1, true), "counters and gauge should be adjacent islands: " .. displayed)
assert(select(2, displayed:gsub("", "")) == 2 and select(2, displayed:gsub("", "")) == 2,
  "narrow layout should contain only counters and gauge islands: " .. displayed)
local wide = winbar_at(120)
local wide_right = assert(wide:match("%%=(.*)$"))
local wide_text = vim.api.nvim_eval_statusline(wide_right, { winid = 0, use_winbar = true, maxwidth = 200 }).str
assert(wide_text:find(" 󰅐 1.3k · $0.002   mock/m1   󰘖 2   9%", 1, true),
  "wide layout should have metrics, model, fold, gauge islands with one space between: " .. wide_text)
assert(select(2, wide_text:gsub("", "")) == 4 and select(2, wide_text:gsub("", "")) == 4,
  "wide layout should contain four islands: " .. wide_text)

print("OK winbar_ctx")
