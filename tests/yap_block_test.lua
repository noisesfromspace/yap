local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })
local icons = require("harness").config.icons

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
-- many OTHER sessions are running (the current buffer's own `󰐰` has no digit).
local buf2 = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "# @user", "", "Second" })
local function left_text(buf)
  local left = yap.winbar(buf):match("^(.-)%%=")
  return left:gsub("%%#.-#", ""):gsub("%%%*", "")
end
local rollup_left = left_text(buf2)
assert(rollup_left == " " .. icons.cap_l .. " " .. icons.running .. "1 " .. icons.cap_r .. " ", "rollup spacing is inconsistent: " .. rollup_left)
local state = require("harness.state")
state.running[buf2] = {}
local with_both = left_text(buf)
state.running[buf2] = nil
assert(with_both:find("  " .. icons.cap_l .. " " .. icons.running .. "1 " .. icons.cap_r, 1, true), "rollup missing after local spinner: " .. with_both)
assert(not with_both:find("   ", 1, true), "left sections should have two-column gaps: " .. with_both)
assert(not left_text(buf):find(icons.running .. "%d"), "running rollup counts the current buffer: " .. left_text(buf))
vim.api.nvim_buf_set_lines(buf2, 0, 0, false, {
  "---", "provider: mock", "model: m1", "description: second session", "models:", "  - mock/m1", "---", "",
})
local titled_rollup = left_text(buf2)
assert(titled_rollup:match("^ " .. icons.cap_l .. " " .. icons.running .. "1 " .. icons.cap_r .. "  second session $"), "title gap differs from the rollup gap: " .. titled_rollup)
assert(not titled_rollup:find("   ", 1, true), "titled left sections should have two-column gaps: " .. titled_rollup)

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
