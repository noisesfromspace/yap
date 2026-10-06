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

-- Changing the CURRENT buffer's model does not touch the global default.
yap.change_model("zeta/m9")
assert(vim.b[buf].yap_provider == "zeta" and vim.b[buf].yap_model == "m9", "change_model did not update the buffer")
local buf2 = yap.new()
assert(vim.b[buf2].yap_provider == "setup" and vim.b[buf2].yap_model == "m0", "change_model leaked into the default")

-- Setting the DEFAULT model persists it for NEW buffers without touching
-- the current buffer.
yap.change_default_model("openai/gpt-6-luna")
assert(
  vim.b[buf].yap_provider == "zeta" and vim.b[buf].yap_model == "m9",
  "change_default_model clobbered the current buffer"
)
local buf3 = yap.new()
assert(
  vim.b[buf3].yap_provider == "openai" and vim.b[buf3].yap_model == "gpt-6-luna",
  "picked combo becomes the default"
)

-- A fresh setup() re-reads the persisted file, so the default survives
-- even though the setup() provider/model differ.
yap.setup({ bin = "test-yap", provider = "setup", model = "m0" })
local buf4 = yap.new()
assert(
  vim.b[buf4].yap_provider == "openai" and vim.b[buf4].yap_model == "gpt-6-luna",
  "persisted default survives re-setup"
)

-- Explicit opts still win over the persisted default.
local buf5 = yap.new({ provider = "deepseek", model = "v4" })
assert(
  vim.b[buf5].yap_provider == "deepseek" and vim.b[buf5].yap_model == "v4",
  "explicit opts override the persisted default"
)

print("OK default model")
