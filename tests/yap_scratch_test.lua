local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup()
local buf = yap.new()
local chat_win = vim.api.nvim_get_current_win()

-- <leader>s is bound in the session buffer
yap.scratch_toggle()
local scratch_win = vim.api.nvim_get_current_win()
assert(scratch_win ~= chat_win, "scratch did not open a new window")
local scratch = vim.api.nvim_get_current_buf()
assert(scratch ~= buf, "scratch is the session buffer")
assert(vim.bo[scratch].buftype == "", "scratch buffer is not file-backed")
assert(vim.bo[scratch].buflisted == false, "scratch buffer should be unlisted")
assert(vim.api.nvim_buf_get_name(scratch):match("%.queue$") ~= nil, "scratch buffer is not a .queue file")
local queue_file = vim.api.nvim_buf_get_name(scratch)
assert(vim.fn.filereadable(queue_file) == 1, "new queue file was not saved automatically")
local initial = { "# @notes", "", "# @steer", "", "# @queue" }
assert(
  table.concat(vim.fn.readfile(queue_file), "\n") == table.concat(initial, "\n"),
  "new queue file has unexpected initial content"
)
assert(not vim.bo[scratch].modified, "automatically saved queue buffer is still modified")
assert(vim.wo.winfixheight == true, "scratch window is not fixed height")
assert(vim.api.nvim_win_get_height(0) == 8, "scratch window height is not 8")
assert(
  vim.api.nvim_win_get_position(scratch_win)[1] > vim.api.nvim_win_get_position(chat_win)[1],
  "scratch window is not below the chat"
)
assert(vim.wo.winbar == "", "scratch window inherited the yap winbar")
assert(vim.wo.foldmethod == "expr", "scratch sections are not foldable")
assert(vim.wo.foldenable, "scratch folding is disabled")

-- Each control section has its own fold; closing one leaves the others open.
vim.api.nvim_win_call(scratch_win, function()
  assert(vim.fn.foldlevel(1) == 1, "notes heading has no fold")
  assert(vim.fn.foldlevel(3) == 1, "steer heading has no fold")
  assert(vim.fn.foldlevel(5) == 1, "queue heading has no fold")
  vim.api.nvim_win_set_cursor(scratch_win, { 1, 0 })
  vim.cmd("normal! zc")
  assert(vim.fn.foldclosed(1) == 1, "notes section did not fold")
  assert(vim.fn.foldclosed(3) == -1, "folding notes also closed steer")
  assert(vim.fn.foldclosed(5) == -1, "folding notes also closed queue")
  vim.cmd("normal! zo")
end)

-- the scratch buffer is a real file: :write saves the live control buffer
local saved = { "# @notes", "a note", "", "# @steer", "", "# @queue", "task one", "task two" }
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, saved)
local ok = pcall(vim.cmd, "write")
assert(ok, "scratch buffer rejected :write")
assert(vim.fn.filereadable(queue_file) == 1, "queue file not written: " .. queue_file)
assert(table.concat(vim.fn.readfile(queue_file), "\n") == table.concat(saved, "\n"), "queue file content mismatch")

-- content survives the toggle
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
assert(#vim.fn.win_findbuf(scratch) == 0, "scratch did not close")
assert(vim.api.nvim_buf_is_valid(scratch), "scratch was wiped on close")
assert(vim.api.nvim_buf_get_lines(scratch, 0, 1, false)[1] == "# @notes", "scratch content not preserved")

-- reopening reuses the same buffer and content
yap.scratch_toggle()
assert(#vim.fn.win_findbuf(scratch) == 1, "scratch did not reopen")
assert(vim.api.nvim_get_current_buf() == scratch, "scratch did not focus on reopen")
assert(vim.api.nvim_buf_get_lines(scratch, 0, 1, false)[1] == "# @notes", "scratch content lost on reopen")
assert(vim.fn.maparg("<leader>s", "n", false, true).buffer == 1, "scratch has no <leader>s map")

-- a recreated scratch buffer loads the persisted sections
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
vim.api.nvim_buf_delete(scratch, { force = true })
vim.b[buf].yap_scratch = nil
yap.scratch_toggle()
local reloaded = vim.api.nvim_get_current_buf()
assert(reloaded ~= scratch, "scratch did not recreate")
local reloaded_text = table.concat(vim.api.nvim_buf_get_lines(reloaded, 0, -1, false), "\n")
assert(reloaded_text == table.concat(saved, "\n"), "saved scratch sections not reloaded")

-- A drawer is anchored below the chat's own window: when the chat is one
-- pane of a vertical split the drawer stays in that column (not full-width),
-- and closing it refocuses the chat.
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
vim.cmd("vsplit")
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
assert(vim.api.nvim_get_current_buf() == reloaded, "scratch did not reopen beside the vertical split")
assert(
  vim.api.nvim_win_get_width(0) == vim.api.nvim_win_get_width(chat_win),
  "scratch drawer is not under the chat column: " .. vim.api.nvim_win_get_width(0) .. " vs " .. vim.api.nvim_win_get_width(chat_win)
)
assert(
  vim.api.nvim_win_get_position(0)[2] == vim.api.nvim_win_get_position(chat_win)[2],
  "scratch drawer is not aligned with the chat column"
)
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
assert(#vim.fn.win_findbuf(reloaded) == 0, "scratch did not close from the vertical split")
assert(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) == buf, "closing scratch did not refocus chat")

print("OK scratch")
