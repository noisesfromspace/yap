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

-- exclusive peek: opening one chip leaves the rest folded
fold.peek(tool1)
assert(vim.fn.foldclosed(tool1) == -1, "peek opened tool1")
assert(vim.fn.foldclosed(tool2) == tool2, "peek kept tool2 folded")
assert(vim.fn.foldclosed(think1) == think1, "peek kept thinking folded")

-- peeking the next one closes the previous (exclusive)
fold.peek(tool2)
assert(vim.fn.foldclosed(tool2) == -1, "peek opened tool2")
assert(vim.fn.foldclosed(tool1) == tool1, "peek closed tool1")

-- <Tab> toggle: open -> close, close -> open
fold.toggle(tool2)
assert(vim.fn.foldclosed(tool2) == tool2, "toggle closed the open tool2")
fold.toggle(tool1)
assert(vim.fn.foldclosed(tool1) == -1, "toggle opened the closed tool1")
assert(vim.fn.foldclosed(tool2) == tool2, "toggle kept tool2 closed")

-- snap-back is keyed to fold OPENERS: prose and yap:ui content do not
-- collapse a peek
fold.after_append(buf, { "some prose line" })
assert(vim.fn.foldclosed(tool1) == -1, "prose append collapsed the peek")
fold.after_append(buf, { "<!-- yap:ui" })
assert(vim.fn.foldclosed(tool1) == -1, "yap:ui append collapsed the peek")

-- a new tool opener snaps back to the view: the peek folds and no manual
-- open leaks into the new fold
vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
  '<!-- yap:tool {"id":"b3","name":"bash","arguments":{}} -->',
  "result three",
  "<!-- /yap:tool -->",
})
local tool3 = 23
fold.after_append(buf, { '<!-- yap:tool {"id":"b3","name":"bash","arguments":{}} -->' })
assert(vim.fn.foldclosed(tool1) == tool1, "opener append did not refold the peek")
assert(vim.fn.foldclosed(tool3) == tool3, "new tool fold leaked open: " .. vim.fn.foldclosed(tool3))

-- heading openers snap too
fold.peek(tool2)
assert(vim.fn.foldclosed(tool2) == -1, "precondition: peeked tool2")
fold.after_append(buf, { "# @user" })
assert(vim.fn.foldclosed(tool2) == tool2, "heading append did not snap back")

-- navigation auto-peek (what ]t maps to): jump then peek the destination
fold.set_view_level(2)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(fold.next_tool() == think1, "next_tool -> thinking block")
fold.peek(vim.api.nvim_win_get_cursor(0)[1])
assert(vim.fn.foldclosed(think1) == -1, "nav peek did not open the thinking block")

-- snap never changes the applied view
assert(fold.level() == 2, "snap changed the applied view level")

print("OK fold_peek")
