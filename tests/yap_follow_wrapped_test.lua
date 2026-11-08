-- A stream often appends several chunks to the SAME last line. Neovim
-- clamps nvim_win_set_cursor({row, #line}) to the last character, so the
-- remembered follower position must be the position Neovim actually set.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local document = require("harness.model.document")
local fold = require("harness.ui.fold")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
local lines = { "# @user", "", "question", "", "# @assistant", "" }
for i = 1, 35 do
  table.insert(lines, 1, "history " .. i)
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
fold.setup_buffer(buf)
fold.set_view_level(2)
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
local wins, expected = document.following_windows(buf), {}
assert(#wins == 1)
local base = vim.fn.winsaveview().topline
for i = 1, 8 do
  document.sync_followers(buf, wins, expected)
  assert(#wins == 1, "lost follower before chunk " .. i)
  document.append_text(buf, string.rep("word ", 30))
  document.follow_windows(buf, wins, expected)
  local cur = vim.api.nvim_win_get_cursor(win)
  local tail = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1]
  assert(cur[1] == vim.api.nvim_buf_line_count(buf) and cur[2] == #tail - 1, "did not follow the last character")
  assert(vim.deep_equal(cur, expected[win]), "stored cursor differs from Neovim's clamped position")
end
assert(vim.fn.winsaveview().topline > base, "wrapped stream did not scroll into view")
vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf) - 1, 0 })
document.sync_followers(buf, wins, expected)
assert(#wins == 0, "explicit cursor movement did not stop following")
print("OK follow cursor on wrapped last line")
