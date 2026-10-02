local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
assert(type(require("harness.document").parse_buffer) == "function", "document module")
assert(type(require("harness.template").template_names) == "function", "template module")
assert(type(require("harness.stream").is_running) == "function", "stream module")
local session = require("harness.session")

-- 1. new buffer with a fake conversation
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system",
  "",
  "You are helpful.",
  "",
  "# @user",
  "",
  "What is the airspeed velocity of an unladen swallow?",
  "",
  "# @assistant",
  "",
  "African or European?",
  "",
  "# @user",
  "",
})

-- 2. save -> file created
session.save(buf)
local path = vim.b[buf].yap_path
assert(path, "no yap_path set")
assert(vim.fn.filereadable(path) == 1, "session file not written: " .. path)
print("saved: " .. path)

-- 3. list finds it with the filename first; descriptions are generated after turns
local items = session.list("cwd")
assert(#items == 1, "expected 1 session, got " .. #items)
assert(items[1].text:match("^" .. vim.pesc(vim.fn.fnamemodify(path, ":t"))), "filename missing: " .. items[1].text)
print("listed: " .. items[1].text)

-- 4. reopen and parse back
vim.cmd("bwipeout!")
yap.open(path)
local msgs = yap.parse_buffer(vim.api.nvim_get_current_buf())
assert(#msgs == 3, "expected 3 messages, got " .. #msgs)
assert(msgs[2].role == "user" and msgs[2].content:match("airspeed"), "msg 2 wrong")
print("reopened and parsed: " .. #msgs .. " messages")
print("OK")
