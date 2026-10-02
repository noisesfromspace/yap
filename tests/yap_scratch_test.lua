local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup()
local buf = yap.new()
local chat_win = vim.api.nvim_get_current_win()

-- <leader>s is bound in the chat buffer
assert(vim.fn.maparg("<leader>s", "n", false, true).buffer == 1, "yap buffer has no <leader>s toggle")

-- toggle on: a nofile, unlisted, fixed-height window above the chat
yap.scratch_toggle()
local scratch_win = vim.api.nvim_get_current_win()
assert(scratch_win ~= chat_win, "scratch did not open a new window")
local scratch = vim.api.nvim_get_current_buf()
assert(scratch ~= buf, "scratch buffer is the chat buffer")
assert(vim.bo[scratch].buftype == "nofile", "scratch buffer is not nofile")
assert(vim.bo[scratch].buflisted == false, "scratch buffer should be unlisted")
assert(vim.wo.winfixheight == true, "scratch window is not fixed height")
assert(vim.api.nvim_win_get_height(0) == 8, "scratch window height is not 8")
assert(
  vim.api.nvim_win_get_position(scratch_win)[1] < vim.api.nvim_win_get_position(chat_win)[1],
  "scratch window is not above the chat"
)
assert(vim.wo.winbar == "", "scratch window inherited the yap winbar")

-- the scratch buffer cannot be written to a file
local ok = pcall(vim.cmd, "write")
assert(not ok, "scratch buffer accepted :write")

-- content survives the toggle (it is a queue, not a throwaway)
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "task one", "task two" })
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
assert(#vim.fn.win_findbuf(scratch) == 0, "scratch did not close")
assert(vim.api.nvim_buf_is_valid(scratch), "scratch buffer was wiped on close")
assert(vim.api.nvim_buf_get_lines(scratch, 0, 1, false)[1] == "task one", "scratch content not preserved")

-- reopening reuses the same buffer and content
yap.scratch_toggle()
assert(#vim.fn.win_findbuf(scratch) == 1, "scratch did not reopen")
assert(vim.api.nvim_get_current_buf() == scratch, "scratch did not focus on reopen")
assert(vim.api.nvim_buf_get_lines(scratch, 0, 1, false)[1] == "task one", "scratch content lost on reopen")
assert(vim.fn.maparg("<leader>s", "n", false, true).buffer == 1, "scratch has no <leader>s toggle")

print("OK scratch")
