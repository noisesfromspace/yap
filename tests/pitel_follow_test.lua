-- Streaming follow: while a reply streams in, a window whose cursor sits on
-- the last line keeps that end in view (like :terminal output); a window
-- scrolled elsewhere is never dragged. Neovim does not scroll a window for an
-- API edit, so the Lua side pins the cursor after every append
-- (follow_windows, harness/init.lua) -- before that the view tracked the end
-- only while an appended chunk happened to land exactly on the cursor (an
-- empty last line, i.e. a chunk ending in a newline) and then stranded it.
local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
pitel.setup({ bin = ROOT .. "/pitel" })

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
    if vim.b[buf].pitel_usage then
      timer:stop()
      return
    end
    n = n + 1
    sample(n)
  end))
  vim.wait(20000, function()
    return vim.b[buf].pitel_usage ~= nil
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
  local buf = pitel.new({ provider = "mock", model = "m1" })
  conversation(buf, 200)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  vim.cmd("normal! zb")
  local base = vim.fn.winsaveview().topline

  pitel.send()
  local bad = {}
  local n = watch(buf, function(i)
    local count = vim.api.nvim_buf_line_count(buf)
    local cur = vim.api.nvim_win_get_cursor(0)
    local last = last_line(buf)
    -- the cursor must ride the end of the streamed text; the chunk that ends
    -- mid-line is the one that used to strand it
    if #last > 0 and (cur[1] ~= count or cur[2] < #last - 1) then
      bad[#bad + 1] = ("sample %d: cursor=%d,%d but the last line is %d:%q"):format(i, cur[1], cur[2], count, last)
    end
  end)
  assert(n >= 5, "sampler barely ran (" .. n .. " samples)")
  assert(#bad == 0, "the view did not follow the stream:\n  " .. table.concat(bad, "\n  "))
  assert(vim.fn.winsaveview().topline > base, "the window never scrolled to follow the end")
  print(("follow: cursor rode the end over %d samples (topline %d -> %d)"):format(n, base, vim.fn.winsaveview().topline))
end

-- ── 2. cursor parked mid-buffer: neither cursor nor view moves ───────────
do
  local buf = pitel.new({ provider = "mock", model = "m1" })
  conversation(buf, 200)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.cmd("normal! zt")
  local row0, top0 = vim.api.nvim_win_get_cursor(0)[1], vim.fn.winsaveview().topline

  pitel.send()
  local drift = {}
  local n = watch(buf, function(i)
    local cur, view = vim.api.nvim_win_get_cursor(0), vim.fn.winsaveview()
    if cur[1] ~= row0 or view.topline ~= top0 then
      drift[#drift + 1] = ("sample %d: cursor=%d (want %d), topline=%d (want %d)"):format(i, cur[1], row0, view.topline, top0)
    end
  end)
  assert(n >= 5, "sampler barely ran (" .. n .. " samples)")
  assert(#drift == 0, "the view moved for a window scrolled away:\n  " .. table.concat(drift, "\n  "))
  print(("no-follow: cursor and view untouched over %d samples"):format(n))
end

print("all follow tests passed")
