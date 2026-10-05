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
assert(wb:find("%#YapIslandCursiveModel#", 1, true), "model is not cursive in its island: " .. wb)
assert(wb:find("%#YapIslandUprightCount#", 1, true), "right usage is not upright in its island: " .. wb)
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
-- Check Neovim's rendered columns, not just highlight markup. Every
-- combination uses the same inset, pill padding and section spacing.
local state = require("harness.state")
local target = vim.api.nvim_create_buf(false, true)
local other = vim.api.nvim_create_buf(false, true)
local waiting = vim.api.nvim_create_buf(false, true)
for _, b in ipairs({ target, other, waiting }) do
  vim.b[b].yap = true
end
vim.b[target].yap_provider = "mock"
vim.b[target].yap_model = "m1"
local function rendered_left()
  local left = assert(yap.winbar(target):match("^(.-)%%="))
  return vim.api.nvim_eval_statusline(left, { winid = 0, use_winbar = true, maxwidth = 200 }).str
end
for mask = 0, 15 do
  state.running[target] = mask % 2 == 1 and {} or nil
  state.running[other] = math.floor(mask / 2) % 2 == 1 and {} or nil
  state.awaiting[waiting] = math.floor(mask / 4) % 2 == 1 and true or nil
  local titled = mask >= 8
  vim.api.nvim_buf_set_lines(target, 0, -1, false,
    titled and { "---", "description: Session title", "---", "" } or { "" })
  local expected = {}
  if state.running[target] then expected[#expected + 1] = "※" end
  if state.running[other] and state.awaiting[waiting] then
    expected[#expected + 1] = " ▶1  ◉1 "
  elseif state.running[other] then
    expected[#expected + 1] = " ▶1 "
  elseif state.awaiting[waiting] then
    expected[#expected + 1] = " ◉1 "
  end
  if titled then expected[#expected + 1] = "Session title" end
  local actual = rendered_left()
  assert(actual == (#expected > 0 and (" " .. table.concat(expected, "  ") .. " ") or ""),
    "inconsistent rendered spacing for state " .. mask .. ": " .. actual)
  local right = assert(yap.winbar(target):match("%%=(.*)$"))
  local rendered_right = vim.api.nvim_eval_statusline(right, { winid = 0, use_winbar = true, maxwidth = 200 }).str
  assert(rendered_right:find(" mock/m1   󰘖 2 ", 1, true),
    "model island should be immediately before fold: " .. rendered_right)
end
-- Theme changes must keep the entire pill on one background, with caps
-- transitioning to the winbar rather than inheriting the count background.
for _, colors in ipairs({ { 0x222222, 0x111111 }, { 0xdddddd, 0xffffff } }) do
  vim.api.nvim_set_hl(0, "NormalFloat", { bg = colors[1] })
  vim.api.nvim_set_hl(0, "WinBar", { bg = colors[2] })
  vim.api.nvim_set_hl(0, "WinBarNC", { bg = 0x333333 })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  for _, group in ipairs({ "YapIsland", "YapIslandBusy", "YapIslandNeeds", "YapIslandCursiveModel", "YapIslandUprightCount", "YapIslandUprightGaugeEmpty", "YapIslandUprightGaugeLabel", "YapIslandUprightGaugeLow" }) do
    assert(vim.api.nvim_get_hl(0, { name = group, link = false }).bg == colors[1],
      group .. " has a mismatched pill background")
  end
  local cap = vim.api.nvim_get_hl(0, { name = "YapIslandCap", link = false })
  assert(cap.fg == colors[1] and cap.bg == colors[2], "rounded caps have square backgrounds")
  local inactive_cap = vim.api.nvim_get_hl(0, { name = "YapIslandCapNC", link = false })
  assert(inactive_cap.fg == colors[1] and inactive_cap.bg == 0x333333,
    "inactive caps must match WinBarNC")
  vim.b[target].yap_usage = { prompt = 1500, completion = 42, cost = 0.00342 }
  state.last_turn[target] = { prompt = 23000, context_window = 250000 }
  local bar = yap.winbar(target)
  local left = assert(bar:match("^(.-)%%="))
  assert(select(2, left:gsub("%%#YapIslandCap#", "")) >= 2,
    "model island needs active caps: " .. left)
  local right = assert(bar:match("%%=(.*)$"))
  assert(select(2, right:gsub("%%#YapIslandCap#", "")) == 4,
    "visible right islands need active caps: " .. right)
  vim.b[target].yap_usage = nil
  state.last_turn[target] = nil
end
-- Opening a picker makes the session window inactive; only its cap surface changes.
state.awaiting[waiting] = true
vim.b[target].yap_usage = { prompt = 1500, completion = 42, cost = 0.00342 }
state.last_turn[target] = { prompt = 23000, context_window = 250000 }
local session_win = vim.api.nvim_get_current_win()
local picker_buf = vim.api.nvim_create_buf(false, true)
local picker_win = vim.api.nvim_open_win(picker_buf, true, {
  relative = "editor", row = 1, col = 1, width = 20, height = 3, style = "minimal",
})
vim.g.statusline_winid = session_win
local inactive_bar = yap.winbar(target)
local inactive_left = assert(inactive_bar:match("^(.-)%%="))
assert(inactive_left:find("%#YapIslandCapNC#", 1, true), "model island needs inactive caps: " .. inactive_left)
local inactive_right = assert(inactive_bar:match("%%=(.*)$"))
assert(inactive_right:find("%#YapIslandCapNC#", 1, true) and not inactive_right:find("%#YapIslandCap#", 1, true),
  "right islands should use inactive caps in picker: " .. inactive_right)
vim.api.nvim_win_close(picker_win, true)
assert(yap.winbar(target):find("%#YapIslandCap#", 1, true), "active caps not restored after picker")
vim.g.statusline_winid = nil
vim.b[target].yap_usage = nil
state.last_turn[target] = nil
vim.api.nvim_buf_delete(picker_buf, { force = true })
state.running[target], state.running[other], state.awaiting[waiting] = nil, nil, nil
-- Dropping the model must also drop its separator, leaving no orphan divider.
vim.cmd("vsplit")
vim.api.nvim_win_set_width(0, 12)
assert(rendered_left() == " Session title ", "narrow title has a dangling separator: " .. rendered_left())
assert(yap.winbar(target):find("%#YapCursiveDescription#", 1, true),
  "session title is not cursive: " .. yap.winbar(target))
assert(not yap.winbar(target):find("%#YapIslandCursiveModel#", 1, true),
  "narrow title kept the model island: " .. yap.winbar(target))
vim.cmd("close")
for _, b in ipairs({ target, other, waiting }) do
  vim.api.nvim_buf_delete(b, { force = true })
end
-- The session title/model are cursive; right-side status groups explicitly
-- suppress italics inherited from their linked theme groups.
for _, group in ipairs({ "YapCursiveModel", "YapCursiveDescription" }) do
  assert(vim.api.nvim_get_hl(0, { name = group, link = false }).italic,
    group .. " should be cursive")
end
for _, group in ipairs({
  "YapUprightIdle", "YapUprightError", "YapUprightNeeds",
  "YapUprightGaugeEmpty", "YapUprightGaugeLabel", "YapUprightGaugeLow",
  "YapUprightGaugeMid", "YapUprightGaugeHigh",
  "YapIslandUprightGaugeEmpty", "YapIslandUprightGaugeLabel",
  "YapIslandUprightGaugeLow", "YapIslandUprightGaugeMid", "YapIslandUprightGaugeHigh",
}) do
  assert(not vim.api.nvim_get_hl(0, { name = group, link = false }).italic,
    group .. " should not be cursive")
end

assert(vim.api.nvim_get_hl(0, { name = "YapIslandCursiveModel", link = false }).bg
    == vim.api.nvim_get_hl(0, { name = "YapIsland", link = false }).bg,
  "model island should share the rollup surface")
assert(vim.api.nvim_get_hl(0, { name = "YapIslandCursiveModel", link = false }).italic,
  "model text should remain italic inside its island")
print("OK winbar_resize")
