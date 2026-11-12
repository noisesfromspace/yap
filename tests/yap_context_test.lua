local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)

local context = require("harness.model.context")

context.reset()
assert(context.snapshot() == nil, "built-in context providers should be absent")

local notified = {}
local notify = vim.notify
vim.notify = function(msg, level)
  notified[#notified + 1] = { msg = msg, level = level }
end

context.register(function()
  error("boom")
end, 10)
context.register(function()
  return "later"
end)
context.register(function()
  return "first"
end, 50)
context.register(function()
  return ""
end, 60)

assert(context.snapshot() == "first\n\nlater", "context providers not ordered/filtered correctly")
assert(#notified == 1 and notified[1].msg:find("context provider failed", 1, true), "failing provider not warned")

vim.notify = notify
context.reset()
print("OK context providers")
