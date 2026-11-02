-- The Ctrl-C mapping should return a stopped turn to the writable prompt, even when
-- the cursor was parked above the stream. A late completion must not steal
-- focus from a different buffer.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = vim.env.YAP_TEST_BIN or ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })

local function start()
  local buf = yap.new({ provider = "mock", model = "m1" })
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "do some work" })
  assert(yap.send(buf))
  assert(vim.wait(10000, function() return yap.is_running(buf) end, 20))
  vim.wait(400) -- wait until the mock's slow tool is in flight
  return buf
end

local buf = start()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local stop_map
for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
  if map.desc == "yap: stop in-flight request" then stop_map = map.callback end
end
assert(stop_map, "missing Ctrl-C mapping")
stop_map() -- invoke the mapping callback (headless :normal intercepts Ctrl-C)
assert(vim.wait(10000, function()
  return not yap.is_running(buf) and vim.api.nvim_win_get_cursor(0)[1] == vim.api.nvim_buf_line_count(buf)
end, 20), "Ctrl-C did not return to the prompt")
local row = vim.api.nvim_buf_line_count(buf)
assert(vim.api.nvim_win_get_cursor(0)[1] == row, "Ctrl-C left cursor away from the prompt")
assert(vim.api.nvim_buf_get_lines(buf, -3, -1, false)[1] == "# @user", "missing writable prompt")
vim.cmd("stopinsert")

local other = start()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local stop_map2
for _, map in ipairs(vim.api.nvim_buf_get_keymap(other, "n")) do
  if map.desc == "yap: stop in-flight request" then stop_map2 = map.callback end
end
stop_map2()
vim.cmd("enew")
local parked = vim.api.nvim_get_current_buf()
assert(vim.wait(10000, function() return not yap.is_running(other) end, 20), "second turn did not stop")
assert(vim.api.nvim_get_current_buf() == parked, "late cancellation stole buffer focus")
assert(vim.api.nvim_get_mode().mode ~= "i", "late cancellation entered insert mode in another buffer")
print("OK Ctrl-C prompt focus")
