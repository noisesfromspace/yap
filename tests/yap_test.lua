local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local document = require("harness.model.document")
assert(type(require("harness.model.document").messages) == "function", "document module")
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

-- 3. A loaded blank session is discoverable even without a generated title
-- or a pending prompt. The saved picker must not hide the round-circle row.
local items = session.list()
assert(#items == 1 and items[1].path == path, "loaded blank session missing: " .. vim.inspect(items))

-- 3b. A renamed transcript names a session and keeps it visible before a
-- description is generated; the directory name is not the display name.
local frontmatter = require("harness.model.frontmatter")
frontmatter.sync(buf) -- the fake conversation above replaced the frontmatter
-- Rename the transcript; the filename is the title.
vim.cmd("file named-session.md")
session.save(buf)
path = vim.b[buf].yap_path -- the renamed transcript
items = session.list()
assert(#items == 1, "expected titled session, got " .. #items)
assert(items[1].text == "named-session", "titled session should show its title: " .. items[1].text)
print("listed: " .. items[1].text)

-- 3c. a fresh session with an unsent # @user prompt is a "scheduled"
-- prompt: it stays listed even before a description is generated, so it can
-- be resumed and sent later. Clearing it leaves the loaded buffer visible;
-- unloading it hides it again until a real prompt is typed.
local scheduled = yap.new()
local scheduled_last = vim.api.nvim_buf_line_count(scheduled) - 1
vim.api.nvim_buf_set_lines(scheduled, scheduled_last, scheduled_last + 1, false, { "scheduled prompt body" })
session.save(scheduled)
local scheduled_path = vim.b[scheduled].yap_path
items = session.list()
local scheduled_item
for _, item in ipairs(items) do
  if item.path == scheduled_path then
    scheduled_item = item
  end
end
assert(scheduled_item, "scheduled prompt should be listed: " .. vim.inspect(items))
vim.api.nvim_buf_set_lines(scheduled, scheduled_last, scheduled_last + 1, false, { "" })
session.save(scheduled)
items = session.list()
assert(
  vim.tbl_contains(
    vim.tbl_map(function(item)
      return item.path
    end, items),
    scheduled_path
  ),
  "loaded empty session should remain listed"
)
vim.api.nvim_buf_call(scheduled, function()
  vim.cmd("bunload!")
end)
items = session.list()
for _, item in ipairs(items) do
  assert(item.path ~= scheduled_path, "unloaded empty session should be hidden: " .. vim.inspect(items))
end

-- 4. reopen and parse back
vim.cmd("bwipeout!")
yap.open(path)
local msgs = document.messages(vim.api.nvim_get_current_buf())
assert(#msgs == 3, "expected 3 messages, got " .. #msgs)
assert(msgs[2].role == "user" and msgs[2].content:match("airspeed"), "msg 2 wrong")
print("reopened and parsed: " .. #msgs .. " messages")
print("OK")
