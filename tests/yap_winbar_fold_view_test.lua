local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local fold = require("harness.ui.fold")
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
  local left = wb:match("^(.-)%%=") or ""
  local center = wb:match("^.-%%=(.-)%%=")
  local function has_switch(section)
    if not section or section == "" then
      return false
    end
    local rendered = vim.api.nvim_eval_statusline(section, { winid = win, use_winbar = true, maxwidth = 120 }).str
    return rendered:find(" 1  2  3 ", 1, true) ~= nil
  end
  -- Active: beside the centered model island. Inactive: stays on the left.
  local in_center = win == vim.api.nvim_get_current_win()
  assert(has_switch(left) == (not in_center), "fold switch on the wrong side of the model: " .. wb)
  if in_center then
    assert(has_switch(center), "fold switch missing from the centered section: " .. wb)
  else
    assert(not has_switch(center), "fold switch leaked into the centered section: " .. wb)
  end
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

-- A lone fold switch must not reserve centering padding that clips the
-- title: once the model island drops, the switch floats in the gap between
-- the title and the usage cluster, so a long title stays fully visible at
-- every width the switch survives. (The bar only reaches these widths after
-- `columns` is raised and applied by returning to a single window.)
do
  local icons = yap.config.icons
  vim.o.columns = 200
  vim.cmd("close") -- drop the narrow right split so `columns` applies
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].number = false
  vim.wo[win].signcolumn = "no"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "---",
    "provider: mock",
    "model: m1",
    "description: A session title long enough to truncate at forty columns",
    "---",
    "",
  })
  vim.b[buf].yap_usage = { prompt = 1500, completion = 42, cost = 0.00342 }
  vim.b[buf].yap_session_usage = { prompt = 999, completion = 99, cost = 0.51 }
  for cols = 110, 85, -1 do
    vim.api.nvim_win_set_width(win, cols)
    local rendered =
      vim.api.nvim_eval_statusline(bar(win), { winid = win, use_winbar = true, maxwidth = cols }).str
    if rendered:find(" 1  2  3 ", 1, true) then
      assert(
        rendered:find(icons.idle, 1, true) and rendered:find("A session title long enough to truncate", 1, true),
        "switch clipped the title at " .. cols .. " cols: " .. rendered
      )
    end
  end
end

print("OK winbar_fold_view")
