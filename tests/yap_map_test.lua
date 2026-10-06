local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ models = { "mock/m1" } })
local buf = yap.new()

local function has_map(desc, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.desc == desc and (lhs == nil or m.lhs == lhs) then
      return true
    end
  end
  return false
end

assert(has_map("yap: change model"), "no <leader>m mapping in yap buffer")
assert(has_map("yap: stop in-flight request", "<C-C>"), "stop mapping is not <C-c>")

-- Picker variants and infrequent operations are Lua/keymap only; the
-- discoverable entry points remain Ex commands.
vim.cmd("runtime plugin/yap.lua")
for _, name in ipairs({
  "YapInsertHere",
  "YapHistory",
  "YapInstances",
  "YapWaiting",
  "YapChangeDefaultModel",
  "YapReload",
}) do
  assert(vim.fn.exists(":" .. name) == 0, name .. " should not be an Ex command")
end
for _, name in ipairs({ "YapInsert", "YapSessions", "YapAlerts", "YapApproval", "YapChangeModel" }) do
  assert(vim.fn.exists(":" .. name) == 2, name .. " should remain an Ex command")
end
for _, name in ipairs({ "insert", "history", "instances", "waiting", "change_default_model" }) do
  assert(type(yap[name]) == "function", name .. " Lua API missing")
end
for _, key in ipairs({ "insert_here", "history", "waiting", "change_default_model" }) do
  assert(yap.config.keymaps[key] ~= "", key .. " keymap disabled")
end
print("OK map")
