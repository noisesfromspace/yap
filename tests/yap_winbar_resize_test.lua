local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local icons = require("harness").config.icons
local spinner_frames = require("harness.spinner").spinner_frames

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
  vim.api.nvim_win_resize(0, cols, -1)
  local wb = yap.winbar(buf)
  vim.cmd("close")
  return wb
end

-- Wide enough for both usage chips; the center island drops if it would
-- collide with the right-hand metrics.
local wb = winbar_at(80)
assert(not wb:match("mock/m1"), "model should yield to wide usage cluster: " .. wb)
assert(wb:find("%#YapIslandUprightCount#", 1, true), "right usage is not upright in its island: " .. wb)
assert(wb:match("1.5k") and wb:match("1.1k"), "wide winbar missing chips: " .. wb)
assert(wb:match("%$0.00342") and wb:match("%$0.51"), "wide winbar missing costs: " .. wb)
assert(wb:match("󰅐") and wb:match("󰆼"), "wide winbar missing icons: " .. wb)
assert(wb:find(icons.idle, 1, true) and not wb:find(icons.waiting, 1, true), "wide winbar state icon wrong: " .. wb)

-- With an empty right side, the model island occupies the physical center.
local saved_usage, saved_total = vim.b[buf].yap_usage, vim.b[buf].yap_session_usage
vim.b[buf].yap_usage, vim.b[buf].yap_session_usage = nil, nil
wb = winbar_at(78)
assert(wb:find("%#YapIslandCursiveModel#", 1, true), "model is not cursive in its island: " .. wb)
assert(select(2, wb:gsub("%%=", "")) == 2, "model should occupy the center section: " .. wb)
local centered = vim.api.nvim_eval_statusline(wb, { winid = 0, use_winbar = true, maxwidth = 78 }).str
local model_start = assert(centered:find(" mock/m1 ", 1, true), "center island missing: " .. centered)
local center_width = vim.fn.strdisplaywidth(" mock/m1 ")
assert(
  math.abs(vim.fn.strdisplaywidth(centered:sub(1, model_start - 1)) + center_width / 2 - 39) <= 1,
  "model island is not centered in 78 columns: " .. centered
)
vim.b[buf].yap_usage, vim.b[buf].yap_session_usage = saved_usage, saved_total

-- Centering must hold when the sides are asymmetric: `%=` centers between
-- the two side clusters, not at the window midpoint, so a lone description
-- (nothing on the right) or a gauge-heavy right side (done glyph left) would
-- otherwise push the island off the true midpoint. A fresh session has no
-- gauge yet; the first completed turn adds one.
local winbar_state = require("harness.state")
local function island_center(cols)
  local wb = winbar_at(cols)
  local rendered = vim.api.nvim_eval_statusline(wb, { winid = 0, use_winbar = true, maxwidth = cols }).str
  local start = rendered:find(" mock/m1 ", 1, true)
  if not start then
    return nil
  end
  local col = vim.fn.strdisplaywidth(rendered:sub(1, start - 1)) + 1
  return col - 1 + vim.fn.strdisplaywidth(" mock/m1 ") / 2
end
vim.b[buf].yap_usage, vim.b[buf].yap_session_usage = nil, nil
local saved_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
-- Right-heavy: done glyph left, context gauge right.
winbar_state.awaiting[buf] = true
winbar_state.last_turn[buf] = { prompt = 120000, context_window = 250000 }
local c = island_center(100)
assert(c and math.abs(c - 50) <= 1, "gauge island off center: " .. tostring(c))
winbar_state.awaiting[buf] = nil
winbar_state.last_turn[buf] = nil
-- Left-heavy: description left, nothing right.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "---",
  "provider: mock",
  "model: m1",
  "description: A session title",
  "---",
  "",
})
c = island_center(100)
assert(c and math.abs(c - 50) <= 1, "description-only island off center: " .. tostring(c))
vim.api.nvim_buf_set_lines(buf, 0, -1, false, saved_lines)
vim.b[buf].yap_usage, vim.b[buf].yap_session_usage = saved_usage, saved_total

-- Narrower: the model island goes first; chips keep tokens + cost.
wb = winbar_at(42)
assert(not wb:match("mock/m1"), "42-col winbar kept the model: " .. wb)
assert(wb:match("1.5k") and wb:match("1.1k"), "42-col winbar missing tokens: " .. wb)
assert(wb:match("%$0.00342") and wb:match("%$0.51"), "42-col winbar missing costs: " .. wb)

-- Narrow: costs drop, tokens survive.
wb = winbar_at(25)
assert(wb:match("1.5k") and wb:match("1.1k"), "narrow winbar missing tokens: " .. wb)
assert(not wb:match("%$"), "narrow winbar kept costs: " .. wb)

-- Very narrow: only the two prices remain.
wb = winbar_at(12)
assert(not wb:match("1.5k") and not wb:match("1.1k"), "tiny winbar kept tokens: " .. wb)
assert(wb:match("%$0.00342") and wb:match("%$0.51"), "tiny winbar missing prices: " .. wb)

-- Equal token totals represent one session: keep only the session chip,
-- including in compact and price-only layouts. Compare raw totals rather
-- than rounded display strings.
vim.b[buf].yap_usage = { prompt = 1000, completion = 42, cost = 0.51 }
vim.b[buf].yap_session_usage = { prompt = 999, completion = 43, cost = 0.51 }
for _, cols in ipairs({ 80, 25, 12 }) do
  wb = winbar_at(cols)
  assert(not wb:find(icons.since, 1, true), "equal tokens kept since-open chip: " .. wb)
  assert(wb:find(icons.total, 1, true), "equal tokens lost session chip: " .. wb)
end
vim.b[buf].yap_usage = { prompt = 1000, completion = 42, cost = 0.51 }
vim.b[buf].yap_session_usage = { prompt = 1000, completion = 43, cost = 0.51 }
wb = winbar_at(80)
assert(
  wb:find(icons.since, 1, true) and wb:find(icons.total, 1, true),
  "different raw token totals were merged: " .. wb
)
vim.b[buf].yap_usage, vim.b[buf].yap_session_usage = saved_usage, saved_total

-- Check Neovim's rendered columns, not just highlight markup. Every
-- combination uses the same inset, pill padding and section spacing.
local state = require("harness.state")
-- The loop below counts only `target`, `other` and `waiting`; the earlier
-- fixture buffer would otherwise register as an idle session.
state.sessions[buf] = nil
local target = vim.api.nvim_create_buf(false, true)
local other = vim.api.nvim_create_buf(false, true)
local waiting = vim.api.nvim_create_buf(false, true)
for _, b in ipairs({ target, other, waiting }) do
  vim.b[b].yap = true
  state.sessions[b] = true
end
vim.b[target].yap_provider = "mock"
vim.b[target].yap_model = "m1"
local function rendered_left()
  local left = assert(yap.winbar(target):match("^(.-)%%="))
  return vim.api.nvim_eval_statusline(left, { winid = 0, use_winbar = true, maxwidth = 200 }).str
end
local function expected_rollup(running_n, waiting_n, stopped_n, error_n, idle_n)
  local chips = {}
  local function add(icon, n)
    if n > 0 then
      chips[#chips + 1] = icon .. n
    end
  end
  add(icons.running, running_n)
  add(icons.waiting, waiting_n)
  add(icons.stopped, stopped_n)
  add(icons.error, error_n)
  add(icons.idle, idle_n)
  return icons.cap_l .. " " .. table.concat(chips, " │ ") .. " " .. icons.cap_r
end
for mask = 0, 15 do
  state.running[target] = mask % 2 == 1 and {} or nil
  state.running[other] = math.floor(mask / 2) % 2 == 1 and {} or nil
  state.awaiting[waiting] = math.floor(mask / 4) % 2 == 1 and true or nil
  local titled = mask >= 8
  vim.api.nvim_buf_set_lines(
    target,
    0,
    -1,
    false,
    titled and { "---", "description: Session title", "---", "" } or { "" }
  )
  local other_running = state.running[other] and 1 or 0
  local waiting_n = state.awaiting[waiting] and 1 or 0
  local idle_n = (state.running[other] and 0 or 1) + (state.awaiting[waiting] and 0 or 1)
  local expected = {
    state.running[target] and "@" or icons.idle,
    expected_rollup(other_running, waiting_n, 0, 0, idle_n),
  }
  if titled then
    expected[#expected + 1] = "Session title"
  end
  local actual = rendered_left()
  for _, g in ipairs(spinner_frames) do
    actual = actual:gsub(vim.pesc(g), "@")
  end
  local expected_str = table.concat(expected, "  ") .. " "
  assert(actual == expected_str, "inconsistent rendered spacing for state " .. mask .. ": " .. actual)
  local bar = yap.winbar(target)
  local center = bar:match("%%=(.-)%%=")
  if center then
    local centered_text = vim.api.nvim_eval_statusline(center, { winid = 0, use_winbar = true, maxwidth = 200 }).str
    if centered_text:find(" mock/m1 ", 1, true) then
      -- Model island present: the switch rides beside it and the island
      -- surface carries the model plus its padding.
      assert(not centered_text:find("󰘖", 1, true), "fold island leaked into center: " .. centered_text)
      assert(centered_text:find(" 1  2  3 ", 1, true), "fold switch missing from center: " .. centered_text)
      assert(
        center:find("%#YapIslandCursiveModel#", 1, true) and select(2, center:gsub("%%#YapIslandUprightCount#", "")) == 2,
        "model and padding must use the island surface: " .. center
      )
    else
      -- The model island has yielded to the crowded layout; the fold
      -- switch stays visible on its own.
      assert(not centered_text:find("mock/m1", 1, true), "model should drop before the switch: " .. centered_text)
      assert(centered_text:find(" 1  2  3 ", 1, true), "fold switch missing after the model dropped: " .. centered_text)
    end
  else
    assert(not bar:find("mock/m1", 1, true), "center should disappear together when crowded: " .. bar)
  end
end
-- Theme changes must keep the entire pill on one background, with caps
-- transitioning to the winbar rather than inheriting the count background.
for _, colors in ipairs({ { 0x222222, 0x111111 }, { 0xdddddd, 0xffffff } }) do
  vim.api.nvim_set_hl(0, "NormalFloat", { bg = colors[1] })
  vim.api.nvim_set_hl(0, "WinBar", { bg = colors[2] })
  vim.api.nvim_set_hl(0, "WinBarNC", { bg = 0x333333 })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  for _, group in ipairs({
    "YapIsland",
    "YapIslandBusy",
    "YapIslandNeeds",
    "YapIslandUprightNeeds",
    "YapIslandError",
    "YapIslandIdle",
    "YapIslandCursiveModel",
    "YapIslandUprightCount",
    "YapIslandUprightGaugeEmpty",
    "YapIslandUprightGaugeLabel",
    "YapIslandUprightGaugeLow",
  }) do
    assert(
      vim.api.nvim_get_hl(0, { name = group, link = false }).bg == colors[1],
      group .. " has a mismatched pill background"
    )
  end
  local cap = vim.api.nvim_get_hl(0, { name = "YapIslandCap", link = false })
  assert(cap.fg == colors[1] and cap.bg == colors[2], "rounded caps have square backgrounds")
  local inactive_cap = vim.api.nvim_get_hl(0, { name = "YapIslandCapNC", link = false })
  assert(inactive_cap.fg == colors[1] and inactive_cap.bg == 0x333333, "inactive caps must match WinBarNC")
  vim.b[target].yap_usage = { prompt = 1500, completion = 42, cost = 0.00342 }
  state.last_turn[target] = { prompt = 23000, context_window = 250000 }
  local bar = yap.winbar(target)
  local center = bar:match("%%=(.-)%%=")
  if center then
    -- The model island, when present, uses active caps; a switch-only
    -- center (model dropped) has no island surface at all.
    if center:find("%#YapIslandCursiveModel#", 1, true) then
      assert(select(2, center:gsub("%%#YapIslandCap#", "")) == 2, "center island needs active caps: " .. center)
    else
      assert(not center:find("%#YapIslandCap#", 1, true), "switch-only center should have no island caps: " .. center)
    end
  end
  local right = assert(bar:match("%%=(.*)$"))
  assert(select(2, right:gsub("%%#YapIslandCap#", "")) >= 4, "visible right islands need active caps: " .. right)
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
  relative = "editor",
  row = 1,
  col = 0,
  width = vim.o.columns,
  height = 3,
  style = "minimal",
})
vim.g.statusline_winid = session_win
vim.b[target].yap_path = "/tmp/inactive-session/session.md"
vim.api.nvim_buf_set_lines(target, 0, -1, false, {
  "---",
  "provider: mock",
  "model: m1",
  "description: Generated description",
  "---",
  "",
})
local saved_target_usage, saved_target_turn = vim.b[target].yap_usage, state.last_turn[target]
local saved_running_target, saved_running_other, saved_waiting =
  state.running[target], state.running[other], state.awaiting[waiting]
vim.b[target].yap_usage, state.last_turn[target] = nil, nil
state.running[target], state.running[other], state.awaiting[waiting] = nil, nil, nil
local inactive_bar = yap.winbar(target)
local inactive_center = inactive_bar:match("%%=(.-)%%=")
assert(inactive_center, "inactive session name should occupy the center island: " .. inactive_bar)
assert(inactive_center:find("inactive%-session"), "inactive session name missing from center: " .. inactive_center)
assert(
  not inactive_center:find("mock/m1", 1, true),
  "inactive session shows model instead of name: " .. inactive_center
)
assert(
  not inactive_bar:find("Generated description", 1, true),
  "inactive session repeats its description: " .. inactive_bar
)
assert(inactive_center:find("%#YapIslandCapNC#", 1, true), "center island needs inactive caps: " .. inactive_center)
-- An inactive session keeps its leftmost state icon (idle/waiting/error/
-- stopped) so attention states are visible from another window, but drops
-- the busy beacon: a generating session needs no attention.
local inactive_left = inactive_bar:match("^(.-)%%=")
assert(
  inactive_left:find("%#YapIdle#" .. icons.idle, 1, true) == 1,
  "inactive idle session should keep its idle icon leftmost: " .. inactive_bar
)
-- The rollup island is the ACTIVE session's dashboard of other sessions,
-- not this window's own signal, so an inactive window must not show it.
assert(
  not inactive_left:find(icons.cap_l, 1, true) and not inactive_left:find(icons.idle .. "2", 1, true),
  "inactive session should hide the other-session rollup island: " .. inactive_left
)
state.awaiting[target] = true
assert(
  yap.winbar(target):find("%#YapNeeds#" .. icons.waiting, 1, true) == 1,
  "inactive waiting session should keep its waiting icon leftmost"
)
state.awaiting[target] = nil
state.errors[target] = "boom"
assert(
  yap.winbar(target):find("%#YapError#" .. icons.error, 1, true) == 1,
  "inactive errored session should keep its error icon leftmost"
)
state.errors[target] = nil
state.stopped[target] = true
assert(
  yap.winbar(target):find("%#YapNeeds#" .. icons.stopped, 1, true) == 1,
  "inactive stopped session should keep its stopped icon leftmost"
)
state.stopped[target] = nil
state.running[target] = {}
assert(
  not yap.winbar(target):find("%#YapBusySpin#", 1, true),
  "inactive generating session should drop the busy beacon"
)
state.running[target] = nil
vim.b[target].yap_usage, state.last_turn[target] = saved_target_usage, saved_target_turn
state.running[target], state.running[other], state.awaiting[waiting] =
  saved_running_target, saved_running_other, saved_waiting
inactive_bar = yap.winbar(target)
local inactive_right = assert(inactive_bar:match(".*%%=(.*)$"))
assert(not inactive_right:find("%S"), "inactive winbar keeps usage/gauge on the right: " .. inactive_bar)
vim.api.nvim_win_close(picker_win, true)
assert(yap.winbar(target):find("%#YapIslandCap#", 1, true), "active caps not restored after picker")
vim.g.statusline_winid = nil
vim.b[target].yap_path = nil
vim.api.nvim_buf_set_lines(target, 0, -1, false, {
  "---",
  "provider: mock",
  "model: m1",
  "description: Session title",
  "---",
  "",
})
vim.b[target].yap_usage = nil
state.last_turn[target] = nil
vim.api.nvim_buf_delete(picker_buf, { force = true })
state.running[target], state.running[other], state.awaiting[waiting] = nil, nil, nil
state.sessions[other], state.sessions[waiting] = nil, nil
-- Two yap sessions side by side: the %! winbar of the inactive window must
-- resolve to that window's own buffer (via g:statusline_winid), not the
-- current window's buffer. nvim_eval_statusline sets g:statusline_winid to
-- the drawn window but leaves the current buffer untouched, so a fallback to
-- nvim_get_current_buf() would leak the active session's identity and usage.
local left_buf = vim.api.nvim_create_buf(false, true)
local right_buf = vim.api.nvim_create_buf(false, true)
for _, b in ipairs({ left_buf, right_buf }) do
  vim.b[b].yap = true
  vim.b[b].yap_provider = "mock"
end
vim.b[left_buf].yap_model = "m1"
vim.b[right_buf].yap_model = "m2"
vim.b[left_buf].yap_path = "/tmp/left-session/session.md"
vim.b[right_buf].yap_path = "/tmp/right-session/session.md"
vim.b[left_buf].yap_usage = { prompt = 1100, completion = 10, cost = 0.01 }
vim.b[right_buf].yap_usage = { prompt = 2200, completion = 20, cost = 0.02 }
vim.api.nvim_win_set_buf(0, left_buf)
vim.wo.winbar = "%!v:lua.require'harness'.winbar()"
local left_win = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
vim.api.nvim_win_set_buf(0, right_buf)
vim.wo.winbar = "%!v:lua.require'harness'.winbar()"
-- Widen the inactive window so its center island and usage render; the
-- active window shrinks to a sliver, which is fine — only the inactive
-- window's own rendering is under test.
vim.api.nvim_win_set_width(left_win, 100)
local inactive_bar =
  vim.api.nvim_eval_statusline(vim.wo[left_win].winbar, { winid = left_win, use_winbar = true, maxwidth = 200 }).str
assert(inactive_bar:find("left-session", 1, true), "inactive winbar shows its own session name: " .. inactive_bar)
assert(
  not inactive_bar:find("right-session", 1, true),
  "inactive winbar leaks the active session name: " .. inactive_bar
)
assert(not inactive_bar:find("1.1k", 1, true), "inactive winbar shows its own usage: " .. inactive_bar)
assert(not inactive_bar:find("2.2k", 1, true), "inactive winbar leaks the active session usage: " .. inactive_bar)
assert(not inactive_bar:find("mock/m2", 1, true), "inactive winbar leaks the active session model: " .. inactive_bar)
vim.cmd("close")
vim.api.nvim_win_set_buf(0, buf)
vim.api.nvim_buf_delete(left_buf, { force = true })
vim.api.nvim_buf_delete(right_buf, { force = true })
-- Dropping the model must also drop its separator, leaving no orphan divider.
vim.cmd("vsplit")
vim.api.nvim_win_resize(0, 12, -1)
assert(
  rendered_left() == icons.idle .. "  Session title ",
  "narrow title has a dangling separator: " .. rendered_left()
)
assert(
  yap.winbar(target):find("%#YapCursiveDescription#", 1, true),
  "session title is not cursive: " .. yap.winbar(target)
)
assert(
  not yap.winbar(target):find("%#YapIslandCursiveModel#", 1, true),
  "narrow title kept the model island: " .. yap.winbar(target)
)
vim.cmd("close")
for _, b in ipairs({ target, other, waiting }) do
  vim.api.nvim_buf_delete(b, { force = true })
end
-- The session title/model are cursive; right-side status groups explicitly
-- suppress italics inherited from their linked theme groups.
for _, group in ipairs({ "YapCursiveModel", "YapCursiveDescription" }) do
  assert(vim.api.nvim_get_hl(0, { name = group, link = false }).italic, group .. " should be cursive")
end
for _, group in ipairs({
  "YapUprightIdle",
  "YapUprightError",
  "YapUprightNeeds",
  "YapUprightGaugeEmpty",
  "YapUprightGaugeLabel",
  "YapUprightGaugeLow",
  "YapUprightGaugeMid",
  "YapUprightGaugeHigh",
  "YapIslandUprightGaugeEmpty",
  "YapIslandUprightGaugeLabel",
  "YapIslandUprightGaugeLow",
  "YapIslandUprightGaugeMid",
  "YapIslandUprightGaugeHigh",
}) do
  assert(not vim.api.nvim_get_hl(0, { name = group, link = false }).italic, group .. " should not be cursive")
end

assert(
  vim.api.nvim_get_hl(0, { name = "YapIslandCursiveModel", link = false }).bg
    == vim.api.nvim_get_hl(0, { name = "YapIsland", link = false }).bg,
  "model island should share the rollup surface"
)
assert(
  vim.api.nvim_get_hl(0, { name = "YapIslandCursiveModel", link = false }).italic,
  "model text should remain italic inside its island"
)
-- Gutter alignment: the state icon (including the running animation) stays
-- centered in the gutter while the rollup island starts at the text edge
-- (the fold-view switch now sits beside the centered model island).
do
  local g_target = vim.api.nvim_create_buf(false, true)
  local g_other = vim.api.nvim_create_buf(false, true)
  for _, b in ipairs({ g_target, g_other }) do
    vim.b[b].yap = true
    state.sessions[b] = true
  end
  vim.b[g_target].yap_provider = "mock"
  vim.b[g_target].yap_model = "m1"
  state.awaiting[g_other] = true
  vim.api.nvim_win_set_buf(0, g_target)
  vim.wo.number = true

  local function textoff()
    return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
  end
  local function positions()
    local rendered =
      vim.api.nvim_eval_statusline(yap.winbar(g_target), { winid = 0, use_winbar = true, maxwidth = 200 }).str
    local cap = assert(rendered:find(icons.cap_l, 1, true), "rollup cap missing: " .. rendered)
    local state_icon = state.running[g_target] and spinner_frames[1] or icons.idle
    local icon_at
    if state.running[g_target] then
      for _, frame in ipairs(spinner_frames) do
        icon_at = rendered:find(frame, 1, true)
        if icon_at then
          state_icon = frame
          break
        end
      end
    else
      icon_at = rendered:find(state_icon, 1, true)
    end
    assert(icon_at, "state icon missing: " .. rendered)
    local icon_col = vim.fn.strdisplaywidth(rendered:sub(1, icon_at - 1))
    local cap_col = vim.fn.strdisplaywidth(rendered:sub(1, cap - 1))
    return icon_col, cap_col
  end

  for _, gutter_width in ipairs({ 3, 4, 5 }) do
    vim.wo.numberwidth = gutter_width
    assert(textoff() == gutter_width, "unexpected gutter width")
    for _, is_running in ipairs({ false, true }) do
      state.running[g_target] = is_running and {} or nil
      local icon_col, cap_col = positions()
      assert(icon_col == math.floor((gutter_width - 1) / 2), "state icon not centered in gutter")
      assert(cap_col == gutter_width, "rollup cap not flush after the gutter")
      assert(cap_col - icon_col - 1 == (gutter_width == 3 and 1 or 2), "state icon spacing changed")
    end
  end

  state.running[g_target] = nil

  vim.wo.number = false
  state.awaiting[g_other] = nil
  vim.api.nvim_buf_delete(g_target, { force = true })
  vim.api.nvim_buf_delete(g_other, { force = true })
end
print("OK winbar_resize")
