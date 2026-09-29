-- Turn-done notification: User PitelTurnDone fires once per completed
-- send with the turn payload; the default handler toasts only for a
-- buffer the user isn't looking at, and the winbar flips to the
-- "reply" (needs you) state instead of idle.
local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")

-- Capture the event independently of the default handler.
local fired, event_buf, turn
vim.api.nvim_create_autocmd("User", {
  pattern = "PitelTurnDone",
  callback = function(a)
    fired = true
    event_buf = a.data and a.data.buf
    turn = a.data and a.data.turn
  end,
})

local orig_notify = vim.notify
local notified = {}
vim.notify = function(msg, level, opts) notified[#notified + 1] = { msg = msg, level = level, opts = opts } end

pitel.setup({ bin = ROOT .. "/pitel", provider = "mock", model = "m1" })

-- A fresh chat has nothing to reply to yet: idle, not "reply".
local buf = pitel.new()
assert(pitel.winbar(buf):match("idle"), "fresh chat should be idle: " .. pitel.winbar(buf))

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @user", "", "hi" })
pitel.send()

local ok = vim.wait(10000, function() return fired end, 50)
assert(ok, "PitelTurnDone did not fire")
assert(event_buf == buf, "event buf mismatch: " .. tostring(event_buf))
assert(type(turn) == "table" and turn.model == "m1", "turn payload missing: " .. vim.inspect(turn))

-- The chat buffer is still current: the default handler must NOT notify.
vim.wait(300)
assert(#notified == 0, "notified while the buffer is current: " .. vim.inspect(notified))

-- The winbar now reports the herdr-style "needs you" state.
local bar = pitel.winbar(buf)
assert(bar:match("reply") and bar:match("PitelNeeds"), "winbar missing reply state: " .. bar)

-- Switch away and fire the event for that buffer: now the default
-- handler notifies (the background-turn case).
vim.notify = orig_notify
vim.cmd("enew")
local notified2 = {}
vim.notify = function(msg, level, opts) notified2[#notified2 + 1] = { msg = msg, level = level } end
vim.api.nvim_exec_autocmds("User", {
  pattern = "PitelTurnDone",
  modeline = false,
  data = { buf = buf, turn = { model = "m1", prompt = 1500, completion = 42, cost = 0.00342, ms = 2100 } },
})
vim.notify = orig_notify
assert(#notified2 == 1, "expected a background-turn notification, got: " .. vim.inspect(notified2))
assert(notified2[1].msg:match("m1 done"), "unexpected message: " .. notified2[1].msg)
print("OK notify")
