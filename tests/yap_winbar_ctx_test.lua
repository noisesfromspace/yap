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
  { prompt = 23000, context_window = 250000, pct = "9%%", hl = "YapGaugeLow" },
  { prompt = 200000, context_window = 250000, pct = "80%%", hl = "YapGaugeMid" },
  { prompt = 240000, context_window = 250000, pct = "96%%", hl = "YapGaugeHigh" },
  { prompt = 250000, context_window = 250000, pct = "100%%", hl = "YapGaugeHigh" },
}) do
  state.last_turn[buf] = case
  for _, width in ipairs({ 60, 12 }) do
    local wb = winbar_at(width)
    assert(not wb:find("󰊚", 1, true), "context glyph shown: " .. wb)
    assert(not wb:match("23k/250k"), "raw context sizes shown: " .. wb)
    assert(graph_width(wb) == 8, "context graph width changed at " .. width .. " cols: " .. wb)
    assert(wb:match(case.hl), "wrong context graph band at " .. case.pct .. ": " .. wb)
    assert(wb:find("%#YapGaugeLabel#", 1, true) or not wb:match("%d+%%"),
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

print("OK winbar_ctx")
