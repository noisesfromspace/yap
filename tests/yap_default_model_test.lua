local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime! plugin/yap.lua")
local yap = require("harness")

-- Don't actually invoke the agent's `models` subcommand in this test.
local system = vim.system
vim.system = function() end

-- No persisted default yet: setup() defaults apply to new buffers.
yap.setup({ bin = "test-yap", provider = "setup", model = "m0" })
local buf = yap.new()
assert(vim.b[buf].yap_provider == "setup" and vim.b[buf].yap_model == "m0", "falls back to setup defaults")

-- Picking a model persists it as the default for NEW buffers.
yap.change_model("openai/gpt-6-luna")
local buf2 = yap.new()
assert(vim.b[buf2].yap_provider == "openai" and vim.b[buf2].yap_model == "gpt-6-luna", "picked combo becomes the default")

-- A fresh setup() re-reads the persisted file, so the default survives
-- even though the setup() provider/model differ.
yap.setup({ bin = "test-yap", provider = "setup", model = "m0" })
local buf3 = yap.new()
assert(vim.b[buf3].yap_provider == "openai" and vim.b[buf3].yap_model == "gpt-6-luna", "persisted default survives re-setup")

-- Explicit opts still win over the persisted default.
local buf4 = yap.new({ provider = "deepseek", model = "v4" })
assert(vim.b[buf4].yap_provider == "deepseek" and vim.b[buf4].yap_model == "v4", "explicit opts override the persisted default")

print("OK default model")
