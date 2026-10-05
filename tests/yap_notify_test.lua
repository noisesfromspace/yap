-- Turn-done notification: User YapTurnDone fires once per completed
-- send with the turn payload; the default handler toasts only for a
-- buffer the user isn't looking at. The winbar shows no idle/waiting
-- glyph — only errors get one.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local state = require("harness.state")

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
local icons = require("harness").config.icons

-- A fresh chat has nothing to reply to yet: no state glyph.
local buf = yap.new()
assert(not yap.winbar(buf):match("idle"), "fresh chat should show no idle: " .. yap.winbar(buf))

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

-- The winbar shows no waiting glyph; the awaiting state only drives the
-- OTHER-buffer rollup island.
local bar = yap.winbar(buf)
assert(not bar:match("waiting"), "winbar should not show waiting: " .. bar)

-- The global rollup: any other yap buffer's winbar counts how many
-- sessions await the user's reply (the herdr-style overview).
local buf2 = yap.new()
local bar2 = yap.winbar(buf2)
assert(bar2:match(icons.waiting .. "1"), "rollup chip missing on the other buffer: " .. bar2)
assert(not bar2:match("idle"), "fresh second buffer should show no idle: " .. bar2)
-- The rollup island sits before the session's model info.
local island_at = assert(bar2:find(icons.waiting .. "1", 1, true), "island missing: " .. bar2)
local model_at = assert(bar2:find("mock/m1", 1, true), "model missing: " .. bar2)
assert(island_at < model_at, "island should precede model: " .. bar2)
assert(not yap.winbar(buf):match(icons.waiting .. "%d"), "rollup counts the current buffer: " .. yap.winbar(buf))
assert(yap.overview(buf2) == icons.waiting .. "1", "overview() wrong: " .. tostring(yap.overview(buf2)))

-- A waiting subagent is not an independent item in the rollup; its parent
-- remains the only session counted as needing a reply.
local subagent = vim.api.nvim_create_buf(false, true)
vim.b[subagent].yap = true
vim.b[subagent].yap_subagent_parent = buf
state.awaiting[subagent] = true
assert(yap.overview(buf2) == icons.waiting .. "1", "waiting subagent was counted separately: " .. tostring(yap.overview(buf2)))
state.awaiting[subagent] = nil
vim.api.nvim_buf_delete(subagent, { force = true })

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

-- :YapInstances / <leader>r list every other open session with its status;
-- waiting sessions sort last because they have a dedicated <leader>w picker.
vim.cmd("enew")
local items, fmt
local orig_select = vim.ui.select
vim.ui.select = function(list, opts, on_choice)
  items = list
  fmt = opts and opts.format_item
end
yap.instances()
vim.ui.select = orig_select
assert(items and #items == 2, "expected both other sessions, got " .. vim.inspect(items))
assert(items[1].buf == buf2, "idle session should sort before waiting sessions")
assert(items[1].status == icons.idle .. " idle", "idle status missing: " .. vim.inspect(items[1]))
assert(items[2].buf == buf, "waiting session should sort last")
assert(items[2].status == icons.waiting .. " waiting", "waiting status missing: " .. vim.inspect(items[2]))
assert(items[2].text:match("^/opt/code/yap  .*%.md$"), "cwd + filename fallback: " .. items[2].text)
assert(fmt(items[2]):match(icons.waiting .. " waiting$"), "status not rendered: " .. fmt(items[2]))

-- :YapWaiting / <leader>w list just the sessions awaiting a reply.
local waiting_items
vim.ui.select = function(list, opts)
  waiting_items = list
end
yap.waiting()
vim.ui.select = orig_select
assert(waiting_items and #waiting_items == 1, "expected one waiting session, got " .. vim.inspect(waiting_items))
assert(waiting_items[1].buf == buf, "waiting picker should list the awaiting session")
assert(waiting_items[1].status == icons.waiting .. " waiting", "waiting status missing: " .. vim.inspect(waiting_items[1]))

-- If the only waiting session is already current, explain that instead of
-- claiming nothing is waiting.
vim.api.nvim_set_current_buf(buf)
local current_notice
local orig_notify_waiting = vim.notify
vim.notify = function(message)
  current_notice = message
end
waiting_items = nil
vim.ui.select = function(list)
  waiting_items = list
end
yap.waiting()
vim.ui.select = orig_select
vim.notify = orig_notify_waiting
assert(not waiting_items, "current waiting session should not appear in the picker")
assert(current_notice == "yap: current session is already open and waiting for a reply",
  "unexpected empty waiting message: " .. tostring(current_notice))
vim.cmd("enew")

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
assert(items and #items == 2, "expected two other sessions, got " .. vim.inspect(items))
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
