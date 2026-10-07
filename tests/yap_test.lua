local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
assert(type(require("harness.document").parse_buffer) == "function", "document module")
assert(type(require("harness.template").template_names) == "function", "template module")
assert(type(require("harness.state").is_running) == "function", "state module")
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

-- 3. list hides unnamed sessions (no description, auto-generated filename);
-- descriptions are generated after turns, so a fresh session is not listed
local items = session.list("cwd")
assert(#items == 0, "expected no listed sessions, got " .. #items)

-- 3b. naming the session with :file keeps it visible before a description
-- is generated (the picker shows the chosen name)
local project_dir = vim.fn.fnamemodify(path, ":h:h")
local named = project_dir .. "/named-session/named-session.md"
vim.api.nvim_buf_set_name(buf, named)
session.save(buf)
items = session.list("cwd")
assert(#items == 1, "expected named session, got " .. #items)
assert(items[1].text == "named-session.md", "named session should show its filename: " .. items[1].text)
print("listed: " .. items[1].text)
local renamed = session.list("renamed")
assert(
  #renamed == 1 and renamed[1].text == "named-session.md",
  "renamed scope should list the :file-named session: " .. vim.inspect(renamed)
)

-- 3c. a fresh session with an unsent # @user prompt is a "scheduled"
-- prompt: it stays listed even before a description is generated, so it can
-- be resumed and sent later. Emptying the prompt hides it again.
local scheduled = yap.new()
local scheduled_last = vim.api.nvim_buf_line_count(scheduled) - 1
vim.api.nvim_buf_set_lines(scheduled, scheduled_last, scheduled_last + 1, false, { "scheduled prompt body" })
session.save(scheduled)
local scheduled_path = vim.b[scheduled].yap_path
items = session.list("cwd")
local scheduled_item
for _, item in ipairs(items) do
  if item.path == scheduled_path then
    scheduled_item = item
  end
end
assert(scheduled_item, "scheduled prompt should be listed: " .. vim.inspect(items))
vim.api.nvim_buf_set_lines(scheduled, scheduled_last, scheduled_last + 1, false, { "" })
session.save(scheduled)
items = session.list("cwd")
for _, item in ipairs(items) do
  assert(item.path ~= scheduled_path, "empty fresh session should stay hidden: " .. vim.inspect(items))
end

-- 4. reopen and parse back
vim.cmd("bwipeout!")
yap.open(path)
local msgs = yap.parse_buffer(vim.api.nvim_get_current_buf())
assert(#msgs == 3, "expected 3 messages, got " .. #msgs)
assert(msgs[2].role == "user" and msgs[2].content:match("airspeed"), "msg 2 wrong")
print("reopened and parsed: " .. #msgs .. " messages")
print("OK")
