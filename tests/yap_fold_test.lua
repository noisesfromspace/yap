local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local fold = require("harness.ui.fold")

local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system",
  "",
  "You are helpful.",
  "",
  "# @user",
  "",
  "Question one here.",
  "",
  "# @assistant",
  "",
  "Answer one.",
  "More answer.",
  "",
  "# @user",
  "",
  "Question two.",
  "",
})
-- yap.new ran setup_buffer on the template; re-apply for our content
fold.setup_buffer(buf)
local structure = require("harness.model.structure")
local p_fold = fold.parse(buf)
local p_struct = structure.parse(buf)
assert(
  p_fold.count == p_struct.count and #p_fold.headings == #p_struct.headings and #p_fold.regions == #p_struct.regions,
  "shared parser outputs match"
)

-- default state is view 2: conversation open, system prompt folded
assert(vim.fn.foldclosed(1) == 1, "system should be folded by default")
assert(vim.fn.foldclosed(5) == -1, "user 1 should be open")
assert(vim.fn.foldclosed(9) == -1, "assistant should be open by default")
assert(vim.fn.foldclosed(14) == -1, "user 2 should be open")
assert(fold.level() == 2, "default view is 2")

-- view 1 reapplied: only user messages and the LAST assistant open
fold.set_view_level(1)
assert(vim.fn.foldclosed(1) == 1, "view 1 folds system")
assert(vim.fn.foldclosed(5) == -1, "view 1 keeps user open")
assert(vim.fn.foldclosed(9) == 9, "view 1 folds assistant")
assert(vim.fn.foldclosed(14) == -1, "view 1 keeps last user open")
assert(fold.level() == 1, "view 1 reports level 1")

-- view 1 is deterministic: partial state gets overwritten
vim.cmd("silent! 9foldopen") -- user opens an assistant fold
assert(vim.fn.foldclosed(9) == -1, "precondition: assistant fold opened")
fold.set_view_level(1)
assert(vim.fn.foldclosed(9) == 9, "view 1 refolds the assistant")

-- view 2: conversation open, but the system prompt stays folded
fold.set_view_level(2)
assert(vim.fn.foldclosed(1) == 1, "view 2 opens the system prompt")
assert(vim.fn.foldclosed(9) == -1, "view 2 folds assistant")
assert(fold.level() == 2, "view 2 reports level 2")

-- view 3: everything open including the system prompt
fold.set_view_level(3)
assert(vim.fn.foldclosed(1) == -1, "view 3 unfolds the system prompt")
assert(vim.fn.foldclosed(9) == -1, "view 3 folds assistant")
assert(fold.level() == 3, "view 3 reports level 3")

-- foldtext
assert(fold.text(9, 12) == "▸ @assistant │ Answer one. (4 lines)", "foldtext: " .. fold.text(9, 12))

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
