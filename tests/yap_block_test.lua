local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })

-- buffer ends ON the user's text (normalize trimmed trailing blanks)
local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @user", "", "Test" })
yap.send()
-- IMMEDIATELY after send (stream still running): blank before # @assistant
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
for i, l in ipairs(lines) do
  print(i, vim.inspect(l))
end
for i = 2, #lines do
  if lines[i]:match("^# @%a+") then
    assert(lines[i - 1] == "" and lines[i - 2] ~= "", "no blank before heading at line " .. i)
  end
end
-- While the first session streams, a second buffer's winbar rolls up how
-- many OTHER sessions are running (the current buffer's own `▶` has no digit).
local buf2 = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "# @user", "", "Second" })
assert(yap.winbar(buf2):match("▶1"), "running rollup missing on the other buffer: " .. yap.winbar(buf2))
assert(yap.winbar(buf2):find("%#YapIsland# %*%#YapIslandBusy#▶1", 1, true),
  "running rollup should have spacing before its icon: " .. yap.winbar(buf2))
assert(not yap.winbar(buf):match("▶%d"), "running rollup counts the current buffer: " .. yap.winbar(buf))
-- A new session must still be able to send while the first streams: each
-- buffer owns its backend, so turns from different sessions run at once.
yap.send()
local done2 = vim.wait(10000, function()
  local l = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
  return l[#l] == "" and l[#l - 1] == "# @user"
end, 100)
assert(done2, "second session did not stream to completion")
-- wait for completion and check the whole buffer obeys R7
local done = vim.wait(8000, function()
  local l = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return l[#l] == "" and l[#l - 1] == "# @user"
end, 100)
assert(done, "stream did not complete")
lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(lines[#lines] == "", "no typing line at end")
for i = 2, #lines do
  if lines[i]:match("^# @%a+") then
    assert(lines[i - 1] == "" and lines[i - 2] ~= "", "blank violation at line " .. i)
  end
end
print("OK")
