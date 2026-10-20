-- Regression: a stream append (document.append_text, what a streaming reply
-- runs on every flush) must never drop the user's visual selection. The
-- incremental fold path once grew the tail fold with `zd`, which jumps the
-- cursor to the fold start and back — `winrestview` restores the cursor but
-- NOT a visual selection, so holding `v` while a block streams in silently
-- deselected. The fix reverts the tail-fold growth to the cursor-free
-- `zE` + re-`:fold` rebuild, so the cursor never moves and visual mode is
-- never left.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local fold = require("harness.ui.fold")
local document = require("harness.model.document")

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
fold.set_view_level(2)

-- A completed thinking block so there is a closed fold below.
document.append_text(buf, "<!-- yap:thinking\nlet me think\nabout it\n-->\n\n")

-- Enter linewise visual mode and select a span.
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.api.nvim_feedkeys("V", "x", false)
vim.api.nvim_win_set_cursor(0, { 5, 0 })
assert(vim.fn.mode(1) == "V", "setup: not in visual mode")

-- Stream several appends (the shape of a live reply). Each one runs the fold
-- reconcile path and must not leave visual mode (which clears the selection).
for _, chunk in ipairs({
  "streamed line one\n",
  "<!-- yap:thinking\nmore\n-->\n\n",
  "streamed line two\n",
}) do
  document.append_text(buf, chunk)
  assert(vim.fn.mode(1) == "V", "visual mode dropped after append " .. vim.inspect(chunk))
end

print("OK visual_selection")
