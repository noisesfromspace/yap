local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ models = { "mock/m1" } })
local buf = yap.new()

local function has_map(desc)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.desc == desc then
      return true
    end
  end
  return false
end

assert(has_map("yap: change model"), "no <leader>m mapping in yap buffer")
assert(has_map("yap: stop in-flight request"), "no <leader>c mapping in yap buffer")
print("OK map")
