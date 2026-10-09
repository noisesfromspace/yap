-- The per-row action popup anchors to the board window, so it renders under
-- the guard board's own column at the board's width — not full-editor width.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local state = require("harness.state")
local guard = require("harness.guard")

local a = yap.new({ provider = "mock", model = "m1" })
state.running[a] = {}
state.pending_approvals[a] = {
  id = "transient-1",
  tool = "bash",
  command = vim.json.encode({ command = "rm -rf /" }),
  reason = "recursive deletion",
  ts = os.date("%Y-%m-%dT%H:%M:%S"),
}

guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(board) == "yap://guard", "guard board did not open")
local board_win = vim.api.nvim_get_current_win()
local board_width = vim.api.nvim_win_get_width(board_win)

vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mtx", false)
local float = vim.api.nvim_get_current_win()
assert(float ~= board_win, "transient did not take focus")

local cfg = vim.api.nvim_win_get_config(float)
assert(cfg.relative == "win", "transient not anchored to a window: " .. tostring(cfg.relative))
assert(cfg.win == board_win, "transient anchored to the wrong window")
assert(cfg.width == board_width, "transient width does not match the board")
assert(vim.api.nvim_win_get_width(float) == board_width, "transient rendered width differs from the board")
-- Same column-anchoring contract as the notes/audit drawers: the popup stays
-- under the board's own column, never the whole tab.
assert(
  vim.api.nvim_win_get_position(float)[2] == vim.api.nvim_win_get_position(board_win)[2],
  "transient is not aligned with the board column"
)
-- And it sits flush against the board's bottom edge, not below the window.
assert(
  vim.api.nvim_win_get_position(float)[1] + vim.api.nvim_win_get_height(float)
    == vim.api.nvim_win_get_position(board_win)[1] + vim.api.nvim_win_get_height(board_win),
  "transient is not anchored to the board's bottom edge"
)

vim.api.nvim_win_close(float, true) -- dismiss the transient
guard.toggle() -- close the board
state.running[a] = nil
state.pending_approvals[a] = nil
print("OK guard transient")
