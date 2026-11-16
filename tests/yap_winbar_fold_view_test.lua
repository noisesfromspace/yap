local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})
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

local function no_switch(win)
  local wb = bar(win)
  assert(not wb:find("YapFoldViewClick", 1, true), "winbar still offers fold controls: " .. wb)
  assert(not wb:find("YapViewActive", 1, true), "winbar still shows fold level: " .. wb)
end

no_switch(left_win)
vim.cmd("vsplit")
local right_win = vim.api.nvim_get_current_win()
fold.set_view_level(3)
no_switch(right_win)
no_switch(left_win)
assert(fold.level(left_win) == 2 and fold.level(right_win) == 3)

vim.api.nvim_set_current_win(left_win)
fold.set_view_level(1)
assert(fold.level(left_win) == 1 and fold.level(right_win) == 3, "view change affected another window")
no_switch(left_win)
vim.api.nvim_set_current_win(right_win)

vim.wo[right_win].number = false
vim.wo[right_win].signcolumn = "no"
no_switch(right_win) -- no gutter required

-- Give the right edge priority when space is scarce.
vim.api.nvim_set_current_win(right_win)
vim.b[buf].yap_usage = { prompt = 1000, completion = 100, cost = 0.02 }
vim.b[buf].yap_session_usage = { prompt = 2500, completion = 100, cost = 0.04 }
vim.api.nvim_win_set_width(right_win, 25)
local narrow = bar(right_win)
assert(narrow:find("$0.02", 1, true) and narrow:find("$0.04", 1, true), narrow)
assert(not narrow:find("YapViewActive", 1, true), "fold level appeared in a narrow bar: " .. narrow)

-- The model island keeps the center as the bar narrows. Fold levels never
-- appear in the bar, but remain available through the view keymaps.
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
    "description: A session title",
    "---",
    "",
  })
  vim.b[buf].yap_usage = { prompt = 1500, completion = 42, cost = 0.00342 }
  vim.b[buf].yap_session_usage = nil
  for cols = 78, 60, -1 do
    vim.api.nvim_win_set_width(win, cols)
    local rendered =
      vim.api.nvim_eval_statusline(bar(win), { winid = win, use_winbar = true, maxwidth = cols }).str
    if rendered:find("mock/m1", 1, true) then
      assert(
        not rendered:find(" 1  2  3 ", 1, true),
        "fold levels appeared at " .. cols .. " cols: " .. rendered
      )
      assert(
        rendered:find(icons.idle, 1, true) and rendered:find("A session title", 1, true),
        "model island clipped the title at " .. cols .. " cols: " .. rendered
      )
    end
  end
end

print("OK winbar_fold_view")
