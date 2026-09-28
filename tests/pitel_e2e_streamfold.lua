local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
pitel.setup({ bin = ROOT .. "/pitel" })
local buf = pitel.new({ provider = "mock", model = "m1" })
pitel.send()
local ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):match("File written%.") ~= nil
end, 100)
assert(ok, "send did not complete")
vim.wait(300) -- let the last scheduled chunk handlers run
vim.cmd("silent! 5foldopen") -- open the assistant block like a user would
local opener
for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if l:match("^<!%-%- pitel:tool") then opener = i break end
end
assert(opener, "no tool header in buffer")
assert(vim.fn.foldclosed(opener) == opener, "streamed tool fold not closed: " .. vim.fn.foldclosed(opener))
-- write/edit headers are slimmed (R12): the arguments carry only the
-- shape, not the content (full args are in the audit log)
local header = vim.api.nvim_buf_get_lines(buf, opener - 1, opener, false)[1]
assert(header:match('"content":"%[%d+ lines%]"'), "write header not slimmed: " .. header)
assert(not header:match("line one about dogs"), "slimmed header leaks content: " .. header)
print("OK e2e")
