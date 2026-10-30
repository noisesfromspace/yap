-- A pending steer icon sits immediately left of the running beacon in the
-- leftmost state-icon slot, not in the model island. The model island stays
-- the bare model pill.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})
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
spinner.begin(buf)
assert(winbar_at(60):find(vim.fn.nr2char(0xF0765), 1, true), "arrival should hold the circle")
state.steer[buf] = "check the tests"
local scratch = vim.api.nvim_create_buf(false, true)
vim.b[buf].yap_scratch = scratch
vim.b[scratch].yap_queue_armed = true
local paired = winbar_at(60)
local q_at, s_at = paired:find(icons.queue, 1, true), paired:find(icons.steer, 1, true)
local b_at = paired:find(spinner.glyph(buf), 1, true)
assert(q_at and s_at and b_at and q_at < s_at and s_at < b_at, "queue/steer/beacon order lost: " .. paired)
vim.b[scratch].yap_queue_armed = false
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
spinner.cancel(buf)
vim.b[scratch].yap_queue_armed = true
assert(winbar_at(60):find(icons.queue, 1, true), "armed queue should replace the beacon")
vim.b[scratch].yap_queue_armed = false
assert(winbar_at(60):find(icons.steer, 1, true), "pending steer should replace the beacon")
state.steer[buf] = nil
state.awaiting[buf] = true
assert(winbar_at(60):find("%#YapNeeds#" .. icons.waiting, 1, true), "completion should show waiting immediately")
state.pending_approvals[buf] = { id = "parked" }
assert(winbar_at(60):find(icons.approval, 1, true), "approval should keep its shield")
state.pending_approvals[buf] = nil
spinner.begin(buf)
state.running[buf] = {}
assert(winbar_at(60):find(vim.fn.nr2char(0xF0765), 1, true), "next turn should start with arrival")
state.running[buf] = nil
spinner.cancel(buf)
print("OK winbar_steer")
