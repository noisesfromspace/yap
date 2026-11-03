-- The statusline redraw is cosmetic: a CTRL-C that lands while the command
-- runs (Nvim reports it as "Keyboard interrupt" and clears got_int) must not
-- throw out of a timer or scheduled callback. Real failures still propagate.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local util = require("harness.util")

local real = vim.cmd.redrawstatus
assert(real ~= nil, "vim.cmd.redrawstatus is missing")

vim.cmd.redrawstatus = function()
  error("Keyboard interrupt")
end
assert(pcall(util.redraw_status), "an interrupt mid-redraw must be swallowed")

vim.cmd.redrawstatus = function()
  error("Vim:E492: Not an editor command")
end
local ok, err = pcall(util.redraw_status)
assert(not ok and tostring(err):find("E492", 1, true), "other errors must propagate")

vim.cmd.redrawstatus = real
assert(pcall(util.redraw_status), "a plain redraw must pass")
print("OK redraw")
