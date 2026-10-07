-- Regression: reconciling a streaming fold must never move the cursor or
-- topline. The old drift path deleted the drifted fold with `zd`, which
-- jumped the viewport to the fold's start line and back on every flush —
-- the source of the streaming-fold flicker. This exercises the drift path
-- (a growing fold) with the cursor parked away from the stream, for both a
-- closed fold (view default) and a user-opened fold (the <leader>2 open-and-
-- watch flow).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local fold = require("harness.fold")
local document = require("harness.document")

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system",
  "",
  "sys",
  "",
  "# @user",
  "",
  "go",
  "",
  "# @assistant",
  "",
})
fold.setup_buffer(buf)
fold.set_view_level(2) -- conversation open, thinking/tool folds closed

-- Open a thinking block; view 2 folds it closed.
document.append_text(buf, "<!-- yap:thinking\n")
local opener
for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if l:match("^<!%-%- yap:thinking") then
    opener = i
    break
  end
end
assert(opener and vim.fn.foldclosed(opener) == opener, "thinking should fold closed in view 2")

-- Park the cursor near the top and pin the viewport, as if reading earlier
-- content while the model streams below.
vim.api.nvim_win_set_cursor(0, { 5, 0 })
vim.cmd("normal! zt")
local v0 = vim.fn.winsaveview()

-- Closed fold: each append grows the fold's range. Reconciling it must not
-- move the cursor or topline, and must keep the fold closed.
for _, l in ipairs({ "let me think\n", "about this\n", "a bit more\n" }) do
  document.append_text(buf, l)
  local v = vim.fn.winsaveview()
  assert(v.lnum == v0.lnum and v.col == v0.col, "cursor moved while streaming a closed fold")
  assert(v.topline == v0.topline, "topline moved while streaming a closed fold")
  assert(vim.fn.foldclosed(opener) == opener, "thinking fold reopened while streaming")
  -- The fold label must stay stable while the block grows: a live line count
  -- repaints the foldtext every flush, which reads as the streaming flicker.
  local label = fold.text(opener, vim.fn.line("$"))
  assert(label:match("…") and not label:match("%d+ lines"), "streaming foldtext not stable: " .. label)
end

-- Open fold: the user za-opens the block to watch it stream. The fold stays
-- open, content streams visibly, and the viewport stays put.
vim.api.nvim_win_set_cursor(0, { opener, 0 })
vim.cmd("normal! za")
assert(vim.fn.foldclosed(opener) == -1, "za did not open thinking")
vim.api.nvim_win_set_cursor(0, { 5, 0 })
vim.cmd("normal! zt")
local v1 = vim.fn.winsaveview()
for _, l in ipairs({ "and some more\n", "final thought\n" }) do
  document.append_text(buf, l)
  local v = vim.fn.winsaveview()
  assert(v.lnum == v1.lnum and v.col == v1.col, "cursor moved while streaming an open fold")
  assert(v.topline == v1.topline, "topline moved while streaming an open fold")
  assert(vim.fn.foldclosed(opener) == -1, "user-opened thinking folded while streaming")
end

-- Closing the block must extend the fold's range to the closer while
-- honoring the user's open choice: the fold stays open, so assert the
-- closer is inside the fold RANGE via foldlevel (foldclosedend is -1 on an
-- open fold).
document.append_text(buf, "-->\n\n")
local closer
for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if l:match("^%-%->%s*$") then
    closer = i
  end
end
assert(closer, "no closer line")
assert(vim.fn.foldclosed(opener) == -1, "open thinking folded when it completed")
assert(vim.fn.foldlevel(closer) > 0, "closer outside the open fold's range")

print("OK fold_noflicker")
