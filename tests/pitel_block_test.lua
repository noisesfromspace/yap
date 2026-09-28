local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
pitel.setup({ bin = ROOT .. "/pitel" })

-- buffer ends ON the user's text (normalize trimmed trailing blanks)
local buf = pitel.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @user", "", "Test" })
pitel.send()
-- IMMEDIATELY after send (stream still running): blank before # @assistant
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
for i, l in ipairs(lines) do print(i, vim.inspect(l)) end
for i = 2, #lines do
  if lines[i]:match("^# @%a+") then
    assert(lines[i-1] == "" and lines[i-2] ~= "", "no blank before heading at line " .. i)
  end
end
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
    assert(lines[i-1] == "" and lines[i-2] ~= "", "blank violation at line " .. i)
  end
end
print("OK")
