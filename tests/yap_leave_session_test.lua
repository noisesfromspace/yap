local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup()

local session = yap.new()
local session_win = vim.api.nvim_get_current_win()
local paths = require("harness.path")
local scratch = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_name(scratch, paths.queue_path(session))
vim.b[session].yap_scratch = scratch
vim.b[scratch].yap_owner = session
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "unsent task" })
vim.cmd("botright 8split")
local scratch_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(scratch_win, scratch)
vim.api.nvim_buf_call(scratch, function() vim.cmd("write") end)
local queue_path = vim.api.nvim_buf_get_name(scratch)

vim.api.nvim_set_current_win(session_win)
yap.live(session)
local tail = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(tail):match("%-tail$"), "live tail did not open")

-- Replacing the session in its window means it is no longer visible. The
-- drawer windows close, but their buffers and the queued work remain intact.
local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(session_win, other)
assert(vim.wait(1000, function()
  return #vim.fn.win_findbuf(scratch) == 0 and #vim.fn.win_findbuf(tail) == 0
end), "scratch/live drawers stayed open after leaving the session")
assert(vim.api.nvim_buf_is_valid(scratch), "scratch buffer was wiped")
assert(vim.api.nvim_buf_is_valid(tail), "tail buffer was wiped")
assert(vim.fn.filereadable(queue_path) == 1, "scratch queue file was removed")
assert(vim.api.nvim_buf_get_lines(scratch, 0, -1, false)[1] == "unsent task", "scratch contents were lost")
print("OK leave-session drawers")
