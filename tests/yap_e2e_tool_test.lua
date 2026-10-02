local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })

local buf = yap.new({ provider = "mock", model = "m1" })
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
for i, l in ipairs(lines) do
  if l == "# @user" then
    vim.api.nvim_buf_set_lines(buf, i - 1, -1, false, { "# @user", "", "List /tmp please" })
    break
  end
end
yap.send()
local done = vim.wait(8000, function()
  local t = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local u = vim.b[buf].yap_usage
  return t:match("directory listing is shown above") ~= nil and u and u.prompt == 250
end, 100)
for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  print(i, vim.inspect(l))
end
assert(done, "tool turn did not complete")
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(text:match("<!%-%- yap:tool %{"), "no tool block in buffer")
assert(text:match("yap"), "no ls result in buffer")
assert(text:match("directory listing is shown above"), "no final answer")

-- follow-up send: parse_buffer reconstructs the pair; mock validates it
vim.api.nvim_buf_set_lines(buf, -2, -1, false, { "and in Paris?" })
yap.send()
local done2 = vim.wait(8000, function()
  local u = vim.b[buf].yap_usage
  return u and u.prompt == 400 and u.completion == 50
end, 100)
assert(done2, "follow-up send failed (history reconstruction rejected?)")
print("OK")
