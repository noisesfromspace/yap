local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
local session = require("harness.session")

-- 1. new buffer with a fake conversation
local buf = pitel.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system", "", "You are helpful.", "",
  "# @user", "", "What is the airspeed velocity of an unladen swallow?", "",
  "# @assistant", "", "African or European?", "",
  "# @user", "",
})

-- 2. save -> file created
session.save(buf)
local path = vim.b[buf].pitel_path
assert(path, "no pitel_path set")
assert(vim.fn.filereadable(path) == 1, "session file not written: " .. path)
print("saved: " .. path)

-- 3. list finds it with the user snippet
local items = session.list("cwd")
assert(#items == 1, "expected 1 session, got " .. #items)
assert(items[1].text:match("airspeed velocity"), "snippet missing: " .. items[1].text)
print("listed: " .. items[1].text)

-- 4. reopen and parse back
vim.cmd("bwipeout!")
pitel.open(path)
local msgs = pitel.parse_buffer(vim.api.nvim_get_current_buf())
assert(#msgs == 3, "expected 3 messages, got " .. #msgs)
assert(msgs[2].role == "user" and msgs[2].content:match("airspeed"), "msg 2 wrong")
print("reopened and parsed: " .. #msgs .. " messages")
print("OK")
