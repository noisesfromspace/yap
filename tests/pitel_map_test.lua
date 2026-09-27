local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("pitel")
pitel.setup({ models = { "mock/m1" } })
local buf = pitel.new()
local found = false
for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
  if m.lhs == " m" or m.lhs:match("m$") and m.desc == "pitel: change model" then
    found = m.desc == "pitel: change model" and (m.lhs == "\\m" or m.lhs:find("m"))
  end
  if m.desc == "pitel: change model" then found = true end
end
assert(found, "no <leader>m mapping in pitel buffer")
print("OK map")
