-- Panels (guard board, scratch, live tail) are plain windows, never
-- 'winfixbuf'-pinned: :e and file pickers reuse them like any other window.
-- The picker's open path is vim.api.nvim_win_set_buf (mini.pick's H.edit),
-- which raises E1513 on a pinned window — so both are asserted here. Their
-- buffers survive (hidden) and their toggles reopen them, so a stray :e or
-- pick never loses panel state.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })
local guard = require("harness.ui.guard")

local buf = yap.new()
local chat_win = vim.api.nvim_get_current_win()
local file = vim.fn.tempname()
vim.fn.writefile({ "hello" }, file)
local target = vim.fn.bufadd(vim.fn.fnamemodify(file, ":."))

-- Guard board: :e reuses the panel window, the board buffer survives and
-- <leader>g reopens it. The picker's nvim_win_set_buf open works too.
guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.wo.winfixbuf == false, "guard board should not be winfixbuf-pinned")
vim.cmd("edit " .. vim.fn.fnameescape(file))
assert(vim.api.nvim_get_current_buf() ~= board, ":e did not reuse the guard window")
assert(vim.api.nvim_buf_is_valid(board), "guard buffer was wiped after :e")
vim.api.nvim_set_current_win(chat_win)
guard.toggle()
assert(vim.api.nvim_get_current_buf() == board, "guard board did not reopen after :e")

-- Scratch: same, plus the notes buffer survives the clobber. Exercise the
-- picker's nvim_win_set_buf path (the E1513 the bug report hit).
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
local scratch = vim.api.nvim_get_current_buf()
assert(vim.wo.winfixbuf == false, "scratch should not be winfixbuf-pinned")
local ok, err = pcall(vim.api.nvim_win_set_buf, vim.api.nvim_get_current_win(), target)
assert(ok, "picker open (nvim_win_set_buf) failed on scratch: " .. tostring(err))
assert(vim.api.nvim_get_current_buf() == target, "picker open did not land in the scratch window")
assert(not vim.wo.spell, "scratch spell checking leaked into the picker window")
assert(vim.api.nvim_buf_is_valid(scratch), "scratch buffer was wiped after picker open")

-- Live tail: the original unpinned panel, still behaves like a plain window.
vim.api.nvim_set_current_win(chat_win)
yap.live(buf)
local tail = vim.api.nvim_get_current_buf()
assert(vim.wo.winfixbuf == false, "live tail should not be winfixbuf-pinned")
vim.cmd("edit " .. vim.fn.fnameescape(file))
assert(vim.api.nvim_buf_is_valid(tail), "tail buffer was wiped after :e")

print("OK panel-edit")
