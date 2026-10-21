-- Closing the guard board when it is the tab's last window must close the
-- tab (like native :q), not raise E444 "Cannot close last window". This
-- happens after :bd on the anchored session: the redirect collapses the
-- session's now-empty split, leaving the board alone in the tab.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local guard = require("harness.ui.guard")

local s = yap.new()
local chat_win = vim.api.nvim_get_current_win()
local full = vim.api.nvim_win_get_height(chat_win)
guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(board) == "yap://guard", "board did not open")
assert(#vim.api.nvim_list_wins() == 2, "board did not open in a split")
assert(
  vim.api.nvim_win_get_height(0) == math.floor(full / 2),
  "board is not half the session window: " .. vim.api.nvim_win_get_height(0) .. " vs " .. math.floor(full / 2)
)

-- Give :q a place to land so closing the board's tab doesn't quit the test.
vim.cmd("tabnew")
vim.cmd("tabprevious")

-- Focus the board window and make it the only window in its tab.
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_buf(w) == board then
    vim.api.nvim_set_current_win(w)
  end
end
vim.cmd("only")
assert(#vim.api.nvim_list_tabpages() == 2, "setup: expected a second tab to remain")

local ok, err = pcall(guard.toggle)
assert(ok, "toggle close raised: " .. tostring(err))
assert(#vim.api.nvim_list_tabpages() == 1, "closing the last-window board should close its tab")
assert(#vim.fn.win_findbuf(board) == 0, "board window still open after close")

print("OK guard close")
