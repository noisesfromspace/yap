local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ models = { "mock/m1" } })
local buf = yap.new()
local found = false
for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
  if m.lhs == " m" or m.lhs:match("m$") and m.desc == "yap: change model" then
    found = m.desc == "yap: change model" and (m.lhs == "\\m" or m.lhs:find("m"))
  end
  if m.desc == "yap: change model" then found = true end
end
assert(found, "no <leader>m mapping in yap buffer")
print("OK map")
