local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup()

local session = yap.new()
local session_win = vim.api.nvim_get_current_win()
local paths = require("harness.path")
yap.scratch_toggle(session)
local scratch = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "unsent task", "", "# @steer", "", "# @queue" })
vim.cmd("write")
local scratch_win = vim.api.nvim_get_current_win()
local notes_path = vim.api.nvim_buf_get_name(scratch)

vim.api.nvim_set_current_win(session_win)
yap.live(session)
local tail = vim.api.nvim_get_current_buf()
assert(vim.fn.bufname(tail):match("^Yap Log: "), "live tail viewer did not open")

-- Replacing the session in its window does not close the jotter or tail.
-- Listing the notes is a user choice and must survive a toggle/reopen.
vim.bo[scratch].buflisted = true
assert(vim.fn.buflisted(scratch) == 1, ":setlocal buflisted did not list notes")
local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(session_win, other)
assert(vim.wait(1000, function()
  return #vim.fn.win_findbuf(scratch) == 1 and #vim.fn.win_findbuf(tail) == 1
end), "leaving the session closed its panels")
assert(vim.fn.buflisted(scratch) == 1, "leaving the session unlisted notes")
assert(vim.fn.filereadable(notes_path) == 1, "scratch notes file was removed")
assert(vim.api.nvim_buf_get_lines(scratch, 0, -1, false)[1] == "unsent task", "scratch contents were lost")

-- Even unloading the owner must leave any panel windows alone.
vim.cmd("bdelete " .. session)
assert(#vim.fn.win_findbuf(scratch) == 1 and #vim.fn.win_findbuf(tail) == 1,
  "deleting the session closed its panels")
vim.fn.bufload(session)
vim.api.nvim_win_set_buf(session_win, session)
vim.api.nvim_set_current_win(session_win)
yap.scratch_toggle(session) -- explicit toggle closes the notes, not the tail
assert(#vim.fn.win_findbuf(scratch) == 0 and #vim.fn.win_findbuf(tail) == 1,
  "manual jotter toggle closed the wrong panel")
assert(vim.fn.buflisted(scratch) == 1, "toggle unlisted notes")
yap.scratch_toggle(session)
assert(vim.api.nvim_get_current_buf() == scratch, "toggle did not reopen notes")
assert(vim.fn.buflisted(scratch) == 1, "reopening notes reset buflisted")
vim.bo[scratch].buflisted = false
assert(vim.fn.buflisted(scratch) == 0, ":setlocal nobuflisted did not hide notes from :ls")

-- A new owner buffer for the same transcript must reuse the open notes.
local session_path = vim.api.nvim_buf_get_name(session)
vim.api.nvim_set_current_win(session_win)
vim.cmd("bwipeout! " .. session)
vim.cmd("edit " .. vim.fn.fnameescape(session_path))
local reopened = vim.api.nvim_get_current_buf()
yap.scratch_toggle(reopened) -- closes the existing notes window
assert(#vim.fn.win_findbuf(scratch) == 0, "reopened session did not find its existing jotter")
yap.scratch_toggle(reopened)
assert(vim.api.nvim_get_current_buf() == scratch, "reopened session created a second jotter")
assert(vim.b[scratch].yap_owner == reopened, "jotter still belongs to the wiped session buffer")

print("OK leave-session panels")
