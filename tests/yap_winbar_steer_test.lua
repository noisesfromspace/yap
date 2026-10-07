-- A pending steer icon joins the model island immediately left of the model
-- name, with a matching blank cell on the right so the model name stays on
-- the window's midpoint. The icon must no longer appear in the left text
-- region (where the tool text lives).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local icons = require("harness").config.icons
local state = require("harness.state")

local buf = yap.new({ provider = "mock", model = "m1" })

local function winbar_at(cols)
  vim.cmd("vsplit")
  vim.api.nvim_win_resize(0, cols, -1)
  local wb = yap.winbar(buf)
  vim.cmd("close")
  return wb
end

-- Without a pending steer the center island is the bare model pill.
local rendered = vim.api.nvim_eval_statusline(winbar_at(60), { winid = 0, use_winbar = true, maxwidth = 60 }).str
assert(rendered:find(" mock/m1 ", 1, true), "bare center island missing: " .. rendered)
assert(not rendered:find(icons.steer, 1, true), "steer icon without pending steer: " .. rendered)

-- With a pending steer, the icon sits left of the model and the model name
-- remains centered.
state.running[buf] = {}
state.steer[buf] = "check the tests"
local wb = winbar_at(60)
local left, center = wb:match("^(.-)%%=(.-)%%=")
assert(left and center, "winbar missing centered section: " .. wb)
local rendered_left = vim.api.nvim_eval_statusline(left, { winid = 0, use_winbar = true, maxwidth = 200 }).str
local rendered_center = vim.api.nvim_eval_statusline(center, { winid = 0, use_winbar = true, maxwidth = 200 }).str
assert(rendered_center:find(icons.steer .. " mock/m1", 1, true), "steer icon not left of model: " .. rendered_center)
assert(not rendered_left:find(icons.steer, 1, true), "steer icon leaked into the left region: " .. rendered_left)
local before, after = rendered_center:match("^(.-)mock/m1(.*)$")
assert(before and after, "model missing from center: " .. rendered_center)
assert(vim.fn.strdisplaywidth(before) == vim.fn.strdisplaywidth(after), "model not centered with steer: " .. rendered_center)

state.running[buf] = nil
state.steer[buf] = nil
print("OK winbar_steer")
