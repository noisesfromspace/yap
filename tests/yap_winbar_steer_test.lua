-- A pending steer icon sits immediately left of the running beacon in the
-- leftmost state-icon slot, not in the model island. The model island stays
-- the bare model pill.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local icons = require("harness").config.icons
local state = require("harness.state")
local spinner = require("harness.ui.spinner")

local buf = yap.new({ provider = "mock", model = "m1" })

local function winbar_at(cols)
  vim.cmd("vsplit")
  vim.api.nvim_win_set_width(0, cols)
  local wb = yap.winbar(buf)
  vim.cmd("close")
  return wb
end

-- Without a pending steer the center island is the bare model pill.
local rendered = vim.api.nvim_eval_statusline(winbar_at(60), { winid = 0, use_winbar = true, maxwidth = 60 }).str
assert(rendered:find(" mock/m1 ", 1, true), "bare center island missing: " .. rendered)
assert(not rendered:find(icons.steer, 1, true), "steer icon without pending steer: " .. rendered)

-- With a pending steer while running, the steer icon sits left of the
-- running beacon; the model island stays bare.
state.running[buf] = {}
state.steer[buf] = "check the tests"
local wb = winbar_at(60)
local glyph = spinner.glyph() -- the same cached frame the bar rendered
local left, center = wb:match("^(.-)%%=(.-)%%=")
assert(left and center, "winbar missing centered section: " .. wb)
local rendered_left = vim.api.nvim_eval_statusline(left, { winid = 0, use_winbar = true, maxwidth = 200 }).str
local rendered_center = vim.api.nvim_eval_statusline(center, { winid = 0, use_winbar = true, maxwidth = 200 }).str
local steer_at = rendered_left:find(icons.steer, 1, true)
local beacon_at = rendered_left:find(glyph, 1, true)
assert(steer_at, "steer icon missing from the left region: " .. rendered_left)
assert(beacon_at, "running beacon missing from the left region: " .. rendered_left)
assert(steer_at < beacon_at, "steer icon not left of the running beacon: " .. rendered_left)
assert(rendered_center:find(" mock/m1 ", 1, true), "model island missing: " .. rendered_center)
assert(not rendered_center:find(icons.steer, 1, true), "steer icon leaked into the model island: " .. rendered_center)

state.running[buf] = nil
state.steer[buf] = nil
print("OK winbar_steer")
