local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local fold = require("harness.fold")
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @system", "instructions", "", "# @user", "hi", "", "# @assistant", "reply" })
fold.setup_buffer(buf)
local left_win = vim.api.nvim_get_current_win()

local function bar(win)
  vim.g.statusline_winid = win
  local result = yap.winbar()
  vim.g.statusline_winid = nil
  return result
end

local function stops(win, selected)
  local wb = bar(win)
  for level = 1, 3 do
    local group = level == selected and "ViewActive" or "ViewInactive"
    assert(wb:find("%" .. level .. "@v:lua.YapFoldViewClick@%#Yap" .. group .. "# " .. level .. " %*%T", 1, true), wb)
  end
  local displayed = vim.api.nvim_eval_statusline(wb, { winid = win, use_winbar = true, maxwidth = 120 }).str
  assert(displayed:find(" 1  2  3 ", 1, true), "fold switch text missing: " .. displayed)
end

stops(left_win, 2)
vim.cmd("vsplit")
local right_win = vim.api.nvim_get_current_win()
fold.set_view_level(3)
stops(right_win, 3)
stops(left_win, 2) -- an inactive split keeps its own view
assert(fold.level(left_win) == 2 and fold.level(right_win) == 3)

local getmousepos = vim.fn.getmousepos
vim.fn.getmousepos = function()
  return { winid = left_win }
end
_G.YapFoldViewClick(1, 1, "l", "    ")
assert(fold.level(left_win) == 1 and fold.level(right_win) == 3, "click changed the wrong window")
stops(left_win, 1)
_G.YapFoldViewClick(2, 1, "r", "    ")
assert(fold.level(left_win) == 1, "right click changed view")
vim.fn.getmousepos = getmousepos

vim.wo[right_win].number = false
vim.wo[right_win].signcolumn = "no"
stops(right_win, 3) -- indicator survives without a gutter

-- Give the right edge priority when space is scarce.
vim.api.nvim_set_current_win(right_win)
vim.b[buf].yap_usage = { prompt = 1000, completion = 100, cost = 0.02 }
vim.b[buf].yap_session_usage = { prompt = 2500, completion = 100, cost = 0.04 }
vim.api.nvim_win_set_width(right_win, 25)
local narrow = bar(right_win)
assert(narrow:find("1.1k", 1, true) and narrow:find("2.6k", 1, true), narrow)
assert(not narrow:find("YapViewActive", 1, true), "switch crowded out usage: " .. narrow)
print("OK winbar_fold_view")
