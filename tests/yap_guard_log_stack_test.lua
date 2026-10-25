-- The guard board and live tool tail form one canonical vertical stack per
-- session: session → guard → log. The cross-toggles keep that order regardless
-- of which panel is opened first — <leader>l inside the board opens the log
-- below it, <leader>g inside the log opens the board above it — and both
-- shortcuts are bound in every yap panel (session, guard board, live tail,
-- scratch).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})
local guard = require("harness.ui.guard")

local s = yap.new()
local chat_win = vim.api.nvim_get_current_win()

local function buf_name(win)
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
end

local function row(win)
  return vim.api.nvim_win_get_position(win)[1]
end

local function height(win)
  return vim.api.nvim_win_get_height(win)
end

local full = height(chat_win)

-- Open the board from the session: it lands below the session window.
guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(board) == "yap://guard", "guard board did not open")
local board_win = vim.api.nvim_get_current_win()
assert(row(board_win) > row(chat_win), "board is not below the session")
assert(vim.fn.maparg("<leader>l", "n", false, true).buffer == 1, "board has no <leader>l map")
assert(vim.fn.maparg("<leader>g", "n", false, true).buffer == 1, "board has no <leader>g map")
-- The board takes half the session window, leaving the session the other half
-- (minus the separator).
assert(
  height(chat_win) == full - math.floor(full / 2) - 1,
  ("board did not split the session in half: %d of %d"):format(height(chat_win), full)
)

-- <leader>l inside the board opens the log directly below it (canonical
-- session → guard → log).
local leader = vim.g.mapleader
if leader == nil or leader == "" then
  leader = "\\"
end
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(leader .. "l", true, false, true), "mtx", false)
local log = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(log):match("%-tail$"), "board <leader>l did not open the log")
local log_win = vim.api.nvim_get_current_win()
assert(row(chat_win) < row(board_win), "session is not above the board")
assert(row(board_win) < row(log_win), "log is not below the board")
-- Stacking the log must not squeeze the session: it takes half the board's
-- height, so the session keeps the half it already had and the two panels
-- share the bottom half.
assert(height(chat_win) == full - math.floor(full / 2) - 1, "opening the log shrank the session")
assert(height(board_win) <= height(chat_win), "board is taller than the session")
assert(height(log_win) <= height(chat_win), "log is taller than the session")

-- Close both, then open the log first and cross-toggle the board in above it.
guard.toggle() -- close board
assert(#vim.fn.win_findbuf(board) == 0, "board did not close")
vim.api.nvim_set_current_win(chat_win)
yap.live() -- close the tail (toggle)
assert(#vim.fn.win_findbuf(log) == 0, "log did not close")

vim.api.nvim_set_current_win(chat_win)
yap.live()
local log_win2 = vim.api.nvim_get_current_win()
assert(buf_name(log_win2):match("%-tail$"), "log did not reopen")
assert(vim.fn.maparg("<leader>g", "n", false, true).buffer == 1, "log has no <leader>g map")

vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(leader .. "g", true, false, true), "mtx", false)
local board_win2 = vim.api.nvim_get_current_win()
assert(buf_name(board_win2) == "yap://guard", "log <leader>g did not open the board")
assert(row(chat_win) < row(board_win2), "board is not below the session")
assert(row(board_win2) < row(log_win2), "board is not above the log")

-- The scratch jotter also binds <leader>g back to the board.
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
assert(vim.fn.maparg("<leader>g", "n", false, true).buffer == 1, "scratch has no <leader>g map")

print("OK guard log stack")
