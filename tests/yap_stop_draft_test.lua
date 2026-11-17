-- Stopping lets an in-flight step/tool finish, then restores the original
-- editable prompt. An incomplete response must not become conversation history.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = vim.env.YAP_TEST_BIN or ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })

local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "Testing123" })
assert(yap.send(buf))
vim.wait(300)
local stop_map
for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
  if map.desc == "yap: stop in-flight request" then stop_map = map.callback end
end
assert(stop_map, "missing Ctrl-C mapping")
stop_map()
assert(yap.is_running(buf), "first press interrupted the provider stream")
assert(vim.wait(10000, function() return not yap.is_running(buf) end, 20), "turn did not stop")
local all = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(not all:find("late answer", 1, true), "stopped reply became a completed answer")
assert(all:match("# @user\n\nTesting123$"), "original prompt was not restored: " .. all)
assert(require("harness.model.document").trailing_role(buf) == "user", "missing writable prompt")
assert(vim.api.nvim_win_get_cursor(0)[1] == vim.api.nvim_buf_line_count(buf), "cursor not at prompt")
vim.cmd("stopinsert")
vim.api.nvim_buf_set_lines(buf, -2, -1, false, { "Testing123 adjusted" })
assert(yap.send(buf))
assert(vim.wait(10000, function() return not yap.is_running(buf) end, 20), "follow-up turn did not finish")
all = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(all:find("Testing123 adjusted", 1, true), "follow-up prompt was lost")
print("OK early stop finishes response")
