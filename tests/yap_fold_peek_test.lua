local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local fold = require("harness.fold")

local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system",
  "",
  "You are helpful.",
  "",
  "# @user",
  "",
  "Question one.",
  "",
  "# @assistant",
  "",
  "<!-- yap:thinking",
  "hmm",
  "-->",
  "",
  '<!-- yap:tool {"id":"b1","name":"bash","arguments":{}} -->',
  "result one",
  "<!-- /yap:tool -->",
  "",
  '<!-- yap:tool {"id":"b2","name":"bash","arguments":{}} -->',
  "result two",
  "<!-- /yap:tool -->",
  "",
})
fold.setup_buffer(buf) -- default view 2: thinking/tools folded

local think1, tool1, tool2 = 11, 15, 19

-- default state: chips folded
assert(vim.fn.foldclosed(think1) == think1, "thinking folded by default")
assert(vim.fn.foldclosed(tool1) == tool1, "tool1 folded by default")
assert(vim.fn.foldclosed(tool2) == tool2, "tool2 folded by default")

-- opening a fold and is NOT exclusive: other folds stay as they are
fold.open(10) -- cursor is in the already-open assistant message
assert(vim.fn.foldclosed(9) == -1, "opening inside an open message closed it")
fold.set_view_level(2) -- clear that pin before checking the tool chips
fold.open(tool1)
assert(vim.fn.foldclosed(tool1) == -1, "open did not open tool1")
assert(vim.fn.foldclosed(tool2) == tool2, "open changed tool2")
assert(vim.fn.foldclosed(think1) == think1, "open changed thinking")
fold.open(tool2)
assert(vim.fn.foldclosed(tool1) == -1, "opening tool2 closed tool1")
assert(vim.fn.foldclosed(tool2) == -1, "open did not open tool2")

-- <Tab> toggle: open -> close, close -> open
fold.toggle(tool2)
assert(vim.fn.foldclosed(tool2) == tool2, "toggle did not close the open tool2")
assert(vim.fn.foldclosed(tool1) == -1, "toggle moved tool1")
fold.toggle(tool1)
assert(vim.fn.foldclosed(tool1) == tool1, "toggle did not close the open tool1")

-- a pin survives a structural append: re-apply clears the manual open and
-- re-opens the pin, while the NEW fold stays at the view's foldlevel
fold.open(tool1)
assert(vim.fn.foldclosed(tool1) == -1, "precondition: tool1 open")
vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
  '<!-- yap:tool {"id":"b3","name":"bash","arguments":{}} -->',
  "result three",
  "<!-- /yap:tool -->",
})
local tool3 = 23
fold.after_append(buf, { '<!-- yap:tool {"id":"b3","name":"bash","arguments":{}} -->' })
assert(vim.fn.foldclosed(tool1) == -1, "append collapsed the pinned tool1")
assert(vim.fn.foldclosed(tool3) == tool3, "new tool fold leaked open: " .. vim.fn.foldclosed(tool3))

-- a heading append re-applies too: the pin survives, nothing leaks open
fold.after_append(buf, { "# @user" })
assert(vim.fn.foldclosed(tool1) == -1, "heading append collapsed the pinned tool1")

-- a view keypress is an explicit reset: it clears every pin
fold.set_view_level(2)
assert(vim.fn.foldclosed(tool1) == tool1, "view keypress did not clear the pin")

-- navigation auto-open (what ]t maps to): jump then pin the destination
fold.set_view_level(2)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(fold.next_tool() == think1, "next_tool -> thinking region")
fold.open(vim.api.nvim_win_get_cursor(0)[1])
assert(vim.fn.foldclosed(think1) == -1, "nav open did not open the thinking region")

-- re-apply never changes the applied view
assert(fold.level() == 2, "re-apply changed the applied view level")

-- View 1: older replies opened with za or <Tab> survive appends, while
-- the newest reply stays folded, including while its text streams.
fold.set_view_level(1)
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "# @assistant", "", "live answer", "" })
fold.after_append(buf, { "# @assistant", "" })
local live_reply = 26
assert(vim.fn.foldclosed(live_reply) == live_reply, "new reply opened in view 1")
vim.api.nvim_win_set_cursor(0, { 9, 0 })
vim.cmd("normal! za")
assert(vim.fn.foldclosed(9) == -1, "za did not open old assistant")
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '<!-- yap:tool {"name":"bash"} -->', "result", "<!-- /yap:tool -->" })
fold.after_append(buf, { '<!-- yap:tool {"name":"bash"} -->' })
assert(vim.fn.foldclosed(9) == -1, "view 1 closed old assistant on tool append")
assert(vim.fn.foldclosed(live_reply) == live_reply, "tool append opened new reply")
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "# @user", "", "next question", "", "# @assistant", "" })
fold.after_append(buf, { "# @assistant" })
assert(vim.fn.foldclosed(9) == -1, "view 1 closed old assistant on new reply")
assert(vim.fn.foldclosed(live_reply) == live_reply, "previous live reply stayed open")

-- The actual stream path appends text into the last line, not whole blocks.
-- Opening an older reply with <Tab> must persist as both text and new
-- structural folds arrive in the newest reply.
fold.set_view_level(1)
fold.toggle(9)
assert(vim.fn.foldclosed(9) == -1, "Tab did not open old assistant in view 1")
require("harness.document").append_text(buf, "streamed text\n")
fold.after_append(buf, { "streamed text", "" })
assert(vim.fn.foldclosed(9) == -1, "text stream closed Tab-opened reply")
local current
for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if line == "# @assistant" then
    current = i
  end
end
assert(vim.fn.foldclosed(current) == current, "text stream opened current reply")
require("harness.document").append_text(buf, "<!-- yap:thinking\nmore\n-->\n")
fold.after_append(buf, { "<!-- yap:thinking", "more", "-->" })
assert(vim.fn.foldclosed(9) == -1, "thinking stream closed Tab-opened reply")
assert(vim.fn.foldclosed(current) == current, "thinking stream opened current reply")

-- A view keypress clears the manual open.
fold.set_view_level(1)
assert(vim.fn.foldclosed(9) == 9, "view reset did not close old reply")
assert(vim.fn.foldclosed(current) == current, "view reset opened current reply")

print("OK fold_peek")
