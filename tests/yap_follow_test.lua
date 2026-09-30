-- Streaming follow: a window whose cursor starts on the last line stays
-- pinned to the real stream end for the whole turn; a window scrolled
-- elsewhere is never moved.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })

--- A conversation long enough that its end is off-screen (the headless
--- window is 22 rows), so following requires real scrolling. Re-applying
--- the view is what opening a session does: replacing the whole buffer
--- leaves the previous manual fold state behind.
local function conversation(buf, filler)
  local lines = { "# @system", "", "system prompt", "", "# @user", "" }
  for i = 1, filler do
    lines[#lines + 1] = "filler line " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  require("harness.fold").set_view_level(1)
  assert(vim.fn.foldclosed(5) == -1, "precondition: the user prompt stays open in view 1")
end

--- Sample the view every 50ms until the turn ends (the mock reports usage on
--- its last chunk; the send pins the cursor right after that, so nothing past
--- it is sampled). Returns the number of samples taken.
local function watch(buf, sample)
  local n, timer = 0, vim.uv.new_timer()
  timer:start(0, 50, vim.schedule_wrap(function()
    if vim.b[buf].yap_usage then
      timer:stop()
      return
    end
    n = n + 1
    sample(n)
  end))
  vim.wait(20000, function()
    return vim.b[buf].yap_usage ~= nil
  end, 50)
  timer:stop()
  timer:close()
  return n
end

local function last_line(buf)
  return vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] or ""
end

-- ── 1. cursor on the last line: the view follows the end ─────────────────
do
  local buf = yap.new({ provider = "mock", model = "m1" })
  conversation(buf, 200)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  vim.cmd("normal! zb")
  local base = vim.fn.winsaveview().topline

  yap.send()
  local n = watch(buf, function(i)
    local count = vim.api.nvim_buf_line_count(buf)
    local cur = vim.api.nvim_win_get_cursor(0)
    local last = last_line(buf)
    assert(cur[1] == count and cur[2] == 0,
      ("sample %d: cursor=%d,%d but stream end is %d:%q"):format(i, cur[1], cur[2], count, last))
  end)
  assert(n >= 5, "sampler barely ran (" .. n .. " samples)")
  assert(vim.fn.winsaveview().topline > base, "the window never scrolled to follow the end")
  assert(vim.wait(2000, function()
    local lines = vim.api.nvim_buf_get_lines(buf, -3, -1, false)
    return lines[1] == "# @user" and lines[2] == ""
  end, 20), "turn did not finish")
  local done = vim.api.nvim_win_get_cursor(0)
  assert(done[1] == vim.api.nvim_buf_line_count(buf) and done[2] == 0,
    "tail follower did not land on the input line below # @user")
  print(("follow: cursor stayed on the real tail and landed on input after %d samples"):format(n))
end

-- ── 2. moving off the tail cancels follow for the rest of the turn ──────
do
  local buf = yap.new({ provider = "mock", model = "m1" })
  conversation(buf, 200)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  yap.send()
  assert(vim.wait(20000, function() return vim.api.nvim_buf_line_count(buf) > 208 end, 20), "stream did not start")
  vim.cmd("normal! k")
  local row0 = vim.api.nvim_win_get_cursor(0)[1]
  local count0 = vim.api.nvim_buf_line_count(buf)
  assert(vim.wait(3000, function() return vim.api.nvim_buf_line_count(buf) > count0 end, 20), "stream did not advance")
  assert(vim.api.nvim_win_get_cursor(0)[1] == row0, "moving off the tail did not cancel follow")
end

-- ── 3. cursor parked mid-buffer: neither cursor nor view moves ───────────
do
  local buf = yap.new({ provider = "mock", model = "m1" })
  conversation(buf, 200)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.cmd("normal! zt")
  local row0, top0 = vim.api.nvim_win_get_cursor(0)[1], vim.fn.winsaveview().topline

  yap.send()
  local drift = {}
  local n = watch(buf, function(i)
    local cur, view = vim.api.nvim_win_get_cursor(0), vim.fn.winsaveview()
    if cur[1] ~= row0 or view.topline ~= top0 then
      drift[#drift + 1] = ("sample %d: cursor=%d (want %d), topline=%d (want %d)"):format(i, cur[1], row0, view.topline, top0)
    end
  end)
  assert(n >= 5, "sampler barely ran (" .. n .. " samples)")
  assert(#drift == 0, "the view moved for a window scrolled away:\n  " .. table.concat(drift, "\n  "))
  assert(vim.wait(2000, function()
    local lines = vim.api.nvim_buf_get_lines(buf, -3, -1, false)
    return lines[1] == "# @user" and lines[2] == ""
  end, 20), "turn did not finish")
  local cur, view = vim.api.nvim_win_get_cursor(0), vim.fn.winsaveview()
  assert(cur[1] == row0 and view.topline == top0,
    "completion moved a window that did not start at the tail")
  print(("no-follow: cursor and view untouched through completion over %d samples"):format(n))
end

-- ── 4. G to the bottom mid-stream adopts the window as a follower ─────────
do
  local buf = yap.new({ provider = "mock", model = "m1" })
  conversation(buf, 200)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.cmd("normal! zt")

  yap.send()
  assert(vim.wait(20000, function() return vim.api.nvim_buf_line_count(buf) > 208 end, 20), "stream did not start")
  vim.cmd("normal! G") -- join the tail after the send; must be adopted
  local n = watch(buf, function(i)
    local count = vim.api.nvim_buf_line_count(buf)
    local cur = vim.api.nvim_win_get_cursor(0)
    assert(cur[1] == count and cur[2] == 0,
      ("sample %d: cursor=%d,%d but stream end is %d"):format(i, cur[1], cur[2], count))
  end)
  assert(n >= 5, "sampler barely ran (" .. n .. " samples)")
  assert(vim.wait(2000, function()
    local lines = vim.api.nvim_buf_get_lines(buf, -3, -1, false)
    return lines[1] == "# @user" and lines[2] == ""
  end, 20), "turn did not finish")
  assert(vim.api.nvim_win_get_cursor(0)[1] == vim.api.nvim_buf_line_count(buf),
    "G-joiner did not stay pinned through the thinking block")
  print(("follow: G-joiner stayed pinned through the thinking block over %d samples"):format(n))
end

print("all follow tests passed")
