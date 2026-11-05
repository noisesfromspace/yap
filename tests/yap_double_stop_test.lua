-- A second Ctrl-C during cancellation kills the serve process instead of
-- waiting for a slow provider, and leaves the session ready for another send.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = vim.env.YAP_TEST_BIN or ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })

local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "Testing hard stop" })
assert(yap.send(buf))
local state = require("harness.state")
local process = state.servers[buf]
local stop_map
for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
  if map.desc == "yap: stop in-flight request" then stop_map = map.callback end
end
assert(stop_map)
vim.wait(300) -- backend has received the turn
stop_map()
assert(state.servers[buf] == process, "first stop should retain the backend")
assert(state.stopped[buf] and yap.is_running(buf), "first stop did not enter stopping state")
local stopping_bar = yap.winbar(buf)
local adjacent = "%#YapNeeds#" .. yap.config.icons.stopped .. "%*%#YapBusySpin#"
assert(stopping_bar:find(adjacent, 1, true), "stop icon is not beside the spinner in the gutter")
-- Simulate a backend unable to finish its cancel; the second press must kill it.
stop_map()
assert(vim.wait(1000, function() return not yap.is_running(buf) end, 10), "hard stop waited for the provider")
assert(not state.servers[buf], "hard stop retained the dead backend")
assert(not state.errors[buf], "hard stop reported an unwanted error")
local stopped_bar = yap.winbar(buf)
assert(not stopped_bar:find("YapBusySpin", 1, true), "stopping spinner lingered")
assert(stopped_bar:find(yap.config.icons.stopped, 1, true), "stopped icon missing")
assert(require("harness.model.document").trailing_role(buf) == "user", "no writable prompt after hard stop")
assert(vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] == "Testing hard stop", "draft was lost")
vim.cmd("stopinsert")
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "Try again" })
assert(yap.send(buf), "could not restart backend after hard stop")
assert(state.servers[buf] ~= process, "reused killed backend")
stop_map()
assert(vim.wait(10000, function() return not yap.is_running(buf) end, 20), "subsequent turn did not cancel")
print("OK double Ctrl-C hard stop")
