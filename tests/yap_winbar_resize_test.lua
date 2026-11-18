local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })
local icons = require("harness").config.icons
local spinner_frames = require("harness.ui.spinner").spinner_frames

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

-- Wide enough for both usage chips and the center island. The model name is
-- the session's identity, so the cost detail yields before it does.
local wb = winbar_at(80)
assert(wb:find(" m1 ", 1, true), "80-col winbar dropped the model island: " .. wb)
assert(not wb:find("mock/m1", 1, true), "winbar should show the model identifier only: " .. wb)
assert(wb:find("%#YapIslandUprightCount#", 1, true), "right usage is not upright in its island: " .. wb)
assert(wb:match("1%.1k") and not wb:match("1%.5k"), "wide winbar should show all-time tokens only: " .. wb)
assert(wb:find(icons.since .. " $0.00342", 1, true), "wide winbar missing since-open cost: " .. wb)
assert(
  wb:find(icons.total, 1, true) and wb:find("$0.51", 1, true),
  "wide winbar missing all-time tokens and cost: " .. wb
)
assert(wb:find(icons.since, 1, true) and wb:find(icons.total, 1, true), "wide winbar missing icons: " .. wb)
assert(wb:find(icons.idle, 1, true) and not wb:find(icons.waiting, 1, true), "wide winbar state icon wrong: " .. wb)

-- With an empty right side, the model island occupies the physical center.
local saved_usage, saved_total = vim.b[buf].yap_usage, vim.b[buf].yap_session_usage
vim.b[buf].yap_usage, vim.b[buf].yap_session_usage = nil, nil
wb = winbar_at(78)
assert(wb:find("%#YapIslandCursiveModel#", 1, true), "model is not cursive in its island: " .. wb)
assert(select(2, wb:gsub("%%=", "")) == 2, "model should occupy the center section: " .. wb)
local centered = vim.api.nvim_eval_statusline(wb, { winid = 0, use_winbar = true, maxwidth = 78 }).str
local model_start = assert(centered:find(" m1 ", 1, true), "center island missing: " .. centered)
local center_width = vim.fn.strdisplaywidth(" m1 ")
assert(
  math.abs(vim.fn.strdisplaywidth(centered:sub(1, model_start - 1)) + center_width / 2 - 39) <= 1,
  "model island is not centered in 78 columns: " .. centered
)
vim.b[buf].yap_usage, vim.b[buf].yap_session_usage = saved_usage, saved_total

-- The identity is one fused island (title │ model) centered on the window's
-- midpoint whatever the sides hold. Both asymmetric cases matter — a lone
-- description with nothing on the right, and a gauge-heavy right side with a
-- done glyph on the left.
local winbar_state = require("harness.state")
local function island_center(cols)
  vim.cmd("vsplit")
  vim.api.nvim_win_set_width(0, cols)
  local win = vim.api.nvim_get_current_win()
  local width = vim.api.nvim_win_get_width(win)
  local saved_winid = vim.g.statusline_winid
  vim.g.statusline_winid = win
  local rendered =
    vim.api.nvim_eval_statusline(yap.winbar(buf), { winid = win, use_winbar = true, maxwidth = width }).str
  vim.cmd("close")
  vim.g.statusline_winid = saved_winid
  -- Locate the fused island by its model text and the caps that enclose it.
  local mi = rendered:find("m1", 1, true)
  local cstart = mi and rendered:sub(1, mi - 1):match(".*()" .. vim.pesc(icons.cap_l))
  local cend = mi and rendered:find(icons.cap_r, mi, true)
  if not (mi and cstart and cend) then
    return nil, width, rendered
  end
  local left_col = vim.fn.strdisplaywidth(rendered:sub(1, cstart - 1))
  local right_col = vim.fn.strdisplaywidth(rendered:sub(1, cend + #icons.cap_r - 1))
  return (left_col + right_col) / 2, width, rendered
end
vim.b[buf].yap_usage, vim.b[buf].yap_session_usage = nil, nil
local saved_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
-- Right-heavy: done glyph left, context gauge right.
winbar_state.awaiting[buf] = true
winbar_state.last_turn[buf] = { prompt = 120000, context_window = 250000 }
local c, cw, crendered = island_center(100)
assert(
  c and math.abs(c - cw / 2) <= 1,
  "fused island off the midpoint under a right-heavy side: "
    .. tostring(c)
    .. " of "
    .. tostring(cw)
    .. " | "
    .. tostring(crendered)
)
winbar_state.awaiting[buf] = nil
winbar_state.last_turn[buf] = nil
-- Left-heavy: description present, nothing on the right.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "---",
  "provider: mock",
  "model: m1",
  "description: A session title",
  "---",
  "",
})
c, cw, crendered = island_center(100)
assert(
  c and math.abs(c - cw / 2) <= 1,
  "fused island off the midpoint under a lone description: "
    .. tostring(c)
    .. " of "
    .. tostring(cw)
    .. " | "
    .. tostring(crendered)
)
assert(
  crendered:find("A session title │ m1", 1, true),
  "description and model should share one island: " .. tostring(crendered)
)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, saved_lines)
vim.b[buf].yap_usage, vim.b[buf].yap_session_usage = saved_usage, saved_total

-- Narrower: the token reading and the since-open cost yield before the
-- model, leaving the all-time cost.
wb = winbar_at(42)
assert(wb:find(" m1 ", 1, true), "42-col winbar dropped the model island: " .. wb)
assert(not wb:match("1%.1k"), "42-col winbar kept token counts: " .. wb)
assert(not wb:find("$0.00342", 1, true), "42-col winbar kept the since-open cost: " .. wb)
assert(wb:find("$0.51", 1, true), "42-col winbar missing the all-time cost: " .. wb)

-- Very narrow: the ledger yields, the model stays.
wb = winbar_at(12)
assert(not wb:find("%$", 1, true), "tiny winbar kept a cost: " .. wb)
assert(wb:find(" m1 ", 1, true), "tiny winbar dropped the model island: " .. wb)

-- Equal spend to date hides the duplicate: the since-open chip adds no
-- information, so only the all-time chip remains.
vim.b[buf].yap_usage = { prompt = 1000, completion = 42, cost = 0.51 }
vim.b[buf].yap_session_usage = { prompt = 999, completion = 43, cost = 0.51 }
for _, cols in ipairs({ 80, 42 }) do
  wb = winbar_at(cols)
  assert(not wb:find(icons.since, 1, true), "equal spend kept since-open chip: " .. wb)
  assert(wb:find(icons.total, 1, true), "equal spend lost session chip: " .. wb)
  assert(wb:find("$0.51", 1, true), "equal spend lost the all-time cost: " .. wb)
end
-- The since-open chip is a cost only; different spend shows both ledgers.
vim.b[buf].yap_usage = { prompt = 1000, completion = 42, cost = 0.51 }
vim.b[buf].yap_session_usage = { prompt = 1000, completion = 43, cost = 0.52 }
wb = winbar_at(80)
assert(wb:find(icons.since .. " $0.51", 1, true), "different spend lost the since-open cost: " .. wb)
assert(wb:find(icons.total, 1, true) and wb:find("$0.52", 1, true), "different spend lost the all-time cost: " .. wb)
assert(wb:find(icons.total .. " 1.0k · $0.52", 1, true), "all-time tokens and cost missing: " .. wb)
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
local function drawn_left()
  local left = assert(yap.winbar(target):match("^(.-)%%="))
  return vim.api.nvim_eval_statusline(left, { winid = 0, use_winbar = true, maxwidth = 200 }).str
end
-- The state icon and rollup are the cluster; whatever follows the pad that
-- holds the description against the centered model island is not part of it.
local function rendered_left()
  local drawn = drawn_left()
  local cluster = drawn:match("^(.-)%s%s%s")
  if cluster then
    return cluster .. " "
  end
  return (drawn:gsub("%s+$", " "))
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
  local expected = { state.running[target] and "@" or icons.idle }
  expected[#expected + 1] = expected_rollup(other_running, waiting_n, 0, 0, idle_n)
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
    assert(centered_text:find("m1", 1, true), "model island missing: " .. centered_text)
    if titled then
      -- Title and model share one fused island, separated by a middot.
      assert(
        centered_text:find("Session title │ m1", 1, true),
        "title should share the model island: " .. centered_text
      )
    end
    assert(not centered_text:find("mock/m1", 1, true), "provider leaked into the center: " .. centered_text)
    assert(not centered_text:find(" 1  2  3 ", 1, true), "fold level leaked into winbar: " .. centered_text)
    assert(center:find("%#YapIslandCursiveModel#", 1, true), "model missing island surface: " .. center)
  else
    assert(not bar:find(" m1 ", 1, true), "center should disappear together when crowded: " .. bar)
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
    assert(center:find("%#YapIslandCursiveModel#", 1, true), "model missing from center: " .. center)
    assert(select(2, center:gsub("%%#YapIslandCap#", "")) == 2, "center island needs active caps: " .. center)
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
assert(inactive_center:find("Generated description"), "inactive session name missing from center: " .. inactive_center)
assert(not inactive_center:find(" m1 ", 1, true), "inactive session shows model instead of name: " .. inactive_center)
assert(inactive_center:find("%#YapIslandCapNC#", 1, true), "center island needs inactive caps: " .. inactive_center)
-- A renamed transcript is the session's permanent title, so its filename
-- wins over the generated description in the center.
vim.api.nvim_buf_set_name(target, vim.fn.fnamemodify(vim.b[target].yap_path, ":h") .. "/Inactive title.md")
local titled_inactive_center = yap.winbar(target):match("%%=(.-)%%=")
assert(
  titled_inactive_center:find("Inactive title"),
  "inactive winbar should use the filename title: " .. titled_inactive_center
)
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
local inactive_running = yap.winbar(target)
assert(not inactive_running:find("%#YapBusySpin#", 1, true), "inactive generating session should drop the busy beacon")
assert(
  inactive_running:find("%#YapBusy#" .. icons.running, 1, true) == 1,
  "inactive generating session should keep a static running icon leftmost: " .. inactive_running
)
state.steer[target] = "check the tests"
assert(
  yap.winbar(target):find("%#YapNeeds#" .. icons.steer, 1, true) == 1,
  "inactive generating session with a pending steer should keep its steer icon leftmost"
)
-- A queued follow-up (the armed # @queue on the session's scratch) gets the
-- same leftmost treatment, and keeps the pending steer beside it.
local scratch = vim.api.nvim_create_buf(false, true)
vim.b[scratch].yap_queue_armed = true
vim.b[target].yap_scratch = scratch
local queued_left = yap.winbar(target):match("^(.-)%%=")
local q_at = assert(
  queued_left:find(icons.queue, 1, true),
  "inactive generating session with a queued message should show the queue icon: " .. queued_left
)
local s_at =
  assert(queued_left:find(icons.steer, 1, true), "a queued message should keep the pending steer icon: " .. queued_left)
assert(q_at < s_at, "the queue icon should sit left of the steer icon: " .. queued_left)
state.steer[target] = nil
state.running[target] = nil
state.awaiting[target] = true
assert(
  yap.winbar(target):find("%#YapNeeds#" .. icons.queue, 1, true) == 1,
  "a queued message outranks the awaiting icon while it waits to send"
)
state.awaiting[target] = nil
vim.b[scratch].yap_queue_armed = false
vim.b[target].yap_scratch = nil
vim.api.nvim_buf_delete(scratch, { force = true })
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
-- The renamed transcript was a probe for the inactive center island; restore
-- the default transcript name so the generated description is the title again.
vim.api.nvim_buf_set_name(target, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(target), ":h") .. "/session.md")
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
assert(not inactive_bar:find(" m2 ", 1, true), "inactive winbar leaks the active session model: " .. inactive_bar)
vim.cmd("close")
vim.api.nvim_win_set_buf(0, buf)
vim.api.nvim_buf_delete(left_buf, { force = true })
vim.api.nvim_buf_delete(right_buf, { force = true })
-- At a sliver of a window the fused island yields its model half and the
-- title shortens into the room left: the title is the session's identity,
-- the model is secondary. No orphan separator is left behind either way.
vim.cmd("vsplit")
vim.api.nvim_win_set_width(0, 12)
local narrow_win = vim.api.nvim_get_current_win()
local narrow_width = vim.api.nvim_win_get_width(narrow_win)
local saved_winid = vim.g.statusline_winid
vim.g.statusline_winid = narrow_win
local narrow_bar = yap.winbar(target)
local narrow_left, narrow_center = narrow_bar:match("^(.-)%%=(.-)%%=")
assert(narrow_left and narrow_center, "narrow bar lost its centered section: " .. narrow_bar)
assert(not narrow_left:find("Session title", 1, true), "title leaked into the left cluster: " .. narrow_bar)
assert(narrow_bar:find("%#YapCursiveDescription#", 1, true), "narrow bar dropped the session title: " .. narrow_bar)
assert(not narrow_bar:find("%#YapIslandCursiveModel#", 1, true), "narrow bar kept the model island: " .. narrow_bar)
local narrow_center_text =
  vim.api.nvim_eval_statusline(narrow_center, { winid = narrow_win, use_winbar = true, maxwidth = narrow_width }).str
assert(not narrow_center_text:find("  ", 1, true), "narrow island has a dangling separator: " .. narrow_bar)
vim.g.statusline_winid = saved_winid
vim.cmd("close")
for _, b in ipairs({ target, other, waiting }) do
  vim.api.nvim_buf_delete(b, { force = true })
end
-- The title is cursive and the model is cursive and bold, so the two halves
-- stay distinct even in a dim colorscheme; the right-side status groups
-- suppress italics inherited from their linked theme groups.
for _, group in ipairs({ "YapCursiveModel", "YapCursiveDescription" }) do
  assert(vim.api.nvim_get_hl(0, { name = group, link = false }).italic, group .. " should be cursive")
end
for _, group in ipairs({
  "YapUprightIdle",
  "YapUprightError",
  "YapUprightNeeds",
  "YapUprightGaugeEmpty",
  "YapUprightGaugeLow",
  "YapUprightGaugeMid",
  "YapUprightGaugeHigh",
  "YapIslandUprightGaugeEmpty",
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
local island_model = vim.api.nvim_get_hl(0, { name = "YapIslandCursiveModel", link = false })
assert(island_model.bold, "model text should be bold inside its island")
assert(island_model.italic, "model text should be italic inside its island")
-- Gutter alignment: the state icon (including the running animation) stays
-- centered in the gutter while the rollup island starts at the text edge.
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
