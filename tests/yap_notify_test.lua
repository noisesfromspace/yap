-- Turn-done notification: User YapTurnDone fires once per completed
-- send with the turn payload; the default handler toasts only for a
-- buffer the user isn't looking at, and the winbar flips to the
-- "waiting" (needs you) state instead of idle.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")

-- Capture the event independently of the default handler.
local fired, event_buf, turn
vim.api.nvim_create_autocmd("User", {
  pattern = "YapTurnDone",
  callback = function(a)
    fired = true
    event_buf = a.data and a.data.buf
    turn = a.data and a.data.turn
  end,
})

local orig_notify = vim.notify
local notified = {}
vim.notify = function(msg, level, opts)
  notified[#notified + 1] = { msg = msg, level = level, opts = opts }
end

yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

-- A fresh chat has nothing to reply to yet: idle, not "waiting".
local buf = yap.new()
assert(yap.winbar(buf):match("idle"), "fresh chat should be idle: " .. yap.winbar(buf))

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @user", "", "hi" })
yap.send()

local ok = vim.wait(10000, function()
  return fired
end, 50)
assert(ok, "YapTurnDone did not fire")
assert(event_buf == buf, "event buf mismatch: " .. tostring(event_buf))
assert(type(turn) == "table" and turn.model == "m1", "turn payload missing: " .. vim.inspect(turn))

-- The chat buffer is still current: the default handler must NOT notify.
vim.wait(300)
assert(#notified == 0, "notified while the buffer is current: " .. vim.inspect(notified))

-- The winbar now reports the herdr-style "needs you" state.
local bar = yap.winbar(buf)
assert(bar:match("waiting") and bar:match("YapNeeds"), "winbar missing waiting state: " .. bar)

-- The global rollup: any other yap buffer's winbar counts how many
-- sessions await the user's reply (the herdr-style overview).
local buf2 = yap.new()
local bar2 = yap.winbar(buf2)
assert(bar2:match("◉1"), "rollup chip missing on the other buffer: " .. bar2)
assert(bar2:match("idle"), "fresh second buffer should be idle: " .. bar2)
-- The rollup island sits before the session's model info.
local island_at = assert(bar2:find("◉1", 1, true), "island missing: " .. bar2)
local model_at = assert(bar2:find("mock/m1", 1, true), "model missing: " .. bar2)
assert(island_at < model_at, "island should precede model: " .. bar2)
assert(not yap.winbar(buf):match("◉%d"), "rollup counts the current buffer: " .. yap.winbar(buf))
assert(yap.overview(buf2) == "◉1", "overview() wrong: " .. tostring(yap.overview(buf2)))

-- Yap buffers are unlisted: they never appear in :ls or buffer pickers
-- (MiniPick.buffers etc.); the pickers are the way back.
assert(not vim.bo[buf].buflisted, "chat buffer should be unlisted")
assert(not vim.bo[buf2].buflisted, "second chat buffer should be unlisted")
local tails_unlisted = true
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b):match("%-tail$") then
    tails_unlisted = tails_unlisted and not vim.bo[b].buflisted
  end
end
assert(tails_unlisted, "tail buffers should be unlisted")

-- Switch away and fire the event for that buffer: now the default
-- handler notifies (the background-turn case).
vim.notify = orig_notify
vim.cmd("enew")
local notified2 = {}
vim.notify = function(msg, level, opts)
  notified2[#notified2 + 1] = { msg = msg, level = level }
end
vim.api.nvim_exec_autocmds("User", {
  pattern = "YapTurnDone",
  modeline = false,
  data = { buf = buf, turn = { model = "m1", prompt = 1500, completion = 42, cost = 0.00342, ms = 2100 } },
})
vim.notify = orig_notify
assert(#notified2 == 1, "expected a background-turn notification, got: " .. vim.inspect(notified2))
assert(notified2[1].msg:match("m1 done"), "unexpected message: " .. notified2[1].msg)

-- :YapInstances / <leader>r list every open session with its status;
-- the awaiting one sorts first, the fresh one is idle.
local items, fmt
local orig_select = vim.ui.select
vim.ui.select = function(list, opts, on_choice)
  items = list
  fmt = opts and opts.format_item
end
yap.instances()
vim.ui.select = orig_select
assert(items and #items == 2, "expected both sessions, got " .. vim.inspect(items))
assert(items[1].buf == buf, "awaiting session should sort first")
assert(items[1].status == "◉ waiting", "waiting status missing: " .. vim.inspect(items[1]))
assert(items[1].text:match("^/opt/code/yap  .*%.md$"), "cwd + filename fallback: " .. items[1].text)
assert(fmt(items[1]):match("◉ waiting$"), "status not rendered: " .. fmt(items[1]))
assert(items[2].buf == buf2, "idle session should sort last")
assert(items[2].status == "○ idle", "idle status missing: " .. vim.inspect(items[2]))

-- A description replaces the filename fallback in the picker label.
local first_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
table.insert(first_lines, 1, "---")
table.insert(first_lines, 2, "provider: mock")
table.insert(first_lines, 3, "model: m1")
table.insert(first_lines, 4, "description: Finished mock turn")
table.insert(first_lines, 5, "---")
table.insert(first_lines, 6, "")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, first_lines)
vim.ui.select = function(list, opts)
  items = list
end
yap.instances()
vim.ui.select = orig_select
assert(items and #items == 2, "expected two sessions, got " .. vim.inspect(items))
local labels = {}
for _, it in ipairs(items) do
  labels[it.text] = true
end
assert(labels["/opt/code/yap  Finished mock turn"], "cwd/description missing from picker: " .. vim.inspect(items))
local has_filename = false
for label in pairs(labels) do
  has_filename = has_filename or label:match("^/opt/code/yap  .*%.md$") ~= nil
end
assert(has_filename, "cwd/filename fallback missing from picker: " .. vim.inspect(items))
print("OK notify")
