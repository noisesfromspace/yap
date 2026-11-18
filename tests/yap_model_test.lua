local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime! plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})
local buf = yap.new({ provider = "mock", model = "m1" })
assert(yap.winbar(buf):find(" m1 ", 1, true), "initial combo")
assert(not yap.winbar(buf):find("mock/", 1, true), "winbar should show the model identifier only")
-- direct argument
local notices = {}
local notify = vim.notify
vim.notify = function(msg)
  notices[#notices + 1] = msg
end
yap.change_model("other/o1")
vim.notify = notify
assert(#notices == 0, "successful model change should not notify: " .. table.concat(notices, " | "))
assert(vim.b[buf].yap_provider == "other" and vim.b[buf].yap_model == "o1", "vars not set")
assert(yap.winbar(buf):find(" o1 ", 1, true), "winbar not updated")
assert(not yap.winbar(buf):find("other/", 1, true), "winbar kept the provider after a model change")
-- Lua plumbing
local command_notices = {}
vim.notify = function(msg)
  command_notices[#command_notices + 1] = msg
end
yap.change_model("mock/m2")
vim.notify = notify
assert(#command_notices == 0, "model command should stay quiet: " .. table.concat(command_notices, " | "))
assert(vim.b[buf].yap_model == "m2", "command failed")
-- invalid argument keeps the old combo
yap.change_model("garbage")
assert(vim.b[buf].yap_model == "m2", "invalid combo clobbered state")

-- A combo may carry slashes and ~ in the model part: `yap models` prints
-- provider + "/" + model, and openrouter publishes ids like
-- "openrouter/anthropic/claude-sonnet-5".
local config = require("harness.config")
local provider, model = config.parse_combo("openrouter/anthropic/claude-sonnet-5")
assert(provider == "openrouter" and model == "anthropic/claude-sonnet-5", "nested combo not parsed")
provider, model = config.parse_combo("openrouter/~deepseek/deepseek-flash-latest")
assert(provider == "openrouter" and model == "~deepseek/deepseek-flash-latest", "~ combo not parsed")
assert(config.parse_combo("nope") == nil, "schemeless combo should not parse")
yap.change_model("openrouter/anthropic/claude-sonnet-5")
assert(
  vim.b[buf].yap_provider == "openrouter" and vim.b[buf].yap_model == "anthropic/claude-sonnet-5",
  "nested combo not applied: " .. tostring(vim.b[buf].yap_model)
)
assert(
  yap.winbar(buf):find(" anthropic/claude-sonnet-5 ", 1, true),
  "nested model identifier missing from winbar: " .. yap.winbar(buf)
)
assert(not yap.winbar(buf):find("openrouter/", 1, true), "winbar leaked the provider")
print("OK model")
