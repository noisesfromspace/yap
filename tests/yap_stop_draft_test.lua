-- Cancel before the backend has emitted anything: edit the original draft.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = vim.env.YAP_TEST_BIN or ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })

local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "Testing123" })
assert(yap.send(buf))
-- Let the serve backend receive the turn before sending the cancellation.
vim.wait(300)
local stop_map
for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
  if map.desc == "yap: stop in-flight request" then stop_map = map.callback end
end
assert(stop_map, "missing Ctrl-C mapping")
stop_map()
assert(vim.wait(10000, function() return not yap.is_running(buf) end, 20), "turn did not cancel")
local lines = vim.api.nvim_buf_get_lines(buf, -4, -1, false)
assert(lines[#lines - 1] == "" and lines[#lines] == "Testing123", "draft changed: " .. vim.inspect(lines))
assert(require("harness.model.document").trailing_role(buf) == "user", "empty assistant turn retained")
assert(vim.api.nvim_win_get_cursor(0)[1] == vim.api.nvim_buf_line_count(buf), "cursor not on original prompt")
assert(vim.api.nvim_win_get_cursor(0)[2] >= #"Testing123" - 1, "cursor not at end of draft")
-- The same draft can be adjusted and resent, without a duplicate role.
vim.cmd("stopinsert")
vim.api.nvim_buf_set_lines(buf, -2, -1, false, { "Testing123 adjusted" })
assert(yap.send(buf))
assert(vim.wait(10000, function()
  return not yap.is_running(buf) and vim.api.nvim_buf_get_lines(buf, -3, -2, false)[1] == "# @user"
end, 20), "adjusted prompt was not sent")
local all = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(all:find("Testing123 adjusted", 1, true), "adjusted prompt was lost")
print("OK early stop restores draft")
