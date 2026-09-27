local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("pitel")
local fold = require("pitel.fold")

local buf = pitel.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system", "", "You are helpful.", "",
  "# @user", "", "Question one here.", "",
  "# @assistant", "", "Answer one.", "More answer.", "",
  "# @user", "", "Question two.", "",
})
-- pitel.new ran setup_buffer on the template; re-apply for our content
fold.apply_default_folds(buf)

-- fruit default: user prompts + last block open, system/assistant closed
assert(vim.fn.foldclosed(1) == 1, "system should be folded")
assert(vim.fn.foldclosed(5) == -1, "user 1 should be open (outline)")
assert(vim.fn.foldclosed(9) == 9, "assistant should be folded")
assert(vim.fn.foldclosed(14) == -1, "last block should be open")

-- view 1 (outline) == fruit default
fold.set_view_level(4) -- disturb state first
fold.set_view_level(1)
assert(vim.fn.foldclosed(1) == 1 and vim.fn.foldclosed(9) == 9, "outline folds system+assistant")
assert(vim.fn.foldclosed(5) == -1 and vim.fn.foldclosed(14) == -1, "outline keeps user+last open")

-- view 2: user only (last block is user here, so same visible set)
fold.set_view_level(2)
assert(vim.fn.foldclosed(9) == 9, "user view folds assistant")

-- view 3: conversation
fold.set_view_level(3)
assert(vim.fn.foldclosed(9) == -1, "conversation opens assistant")
assert(vim.fn.foldclosed(1) == 1, "conversation keeps system folded")

-- view 4: full
fold.set_view_level(4)
assert(vim.fn.foldclosed(1) == -1, "full opens everything")

-- foldtext
assert(fold.text(9, 12) == "▸ @assistant │ Answer one.  (4 lines)", "foldtext: " .. fold.text(9, 12))

-- navigation
vim.api.nvim_win_set_cursor(0, { 1, 0 })
fold.next_user_message()
assert(vim.api.nvim_win_get_cursor(0)[1] == 5, "next user -> 5")
fold.next_assistant_message()
assert(vim.api.nvim_win_get_cursor(0)[1] == 9, "next assistant -> 9")
fold.next_message()
assert(vim.api.nvim_win_get_cursor(0)[1] == 14, "next message -> 14")
fold.prev_message()
assert(vim.api.nvim_win_get_cursor(0)[1] == 9, "prev message -> 9")
print("OK")
