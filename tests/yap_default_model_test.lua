local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")

-- Model groups are the only source of new-session defaults; old cached
-- per-computer selections must not override them.
local path = vim.fn.stdpath("cache") .. "/yap/default"
vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
vim.fn.writefile({ "openai/old" }, path)
local system = vim.system
vim.system = function() end

yap.setup({ bin = "test-yap", model_groups = { agent = "setup/m0", flash = "" }})
local buf = yap.new()
assert(vim.b[buf].yap_provider == "setup" and vim.b[buf].yap_model == "m0", "agent group is not the default")

yap.change_model("zeta/m9")
assert(vim.b[buf].yap_provider == "zeta" and vim.b[buf].yap_model == "m9", "session model not changed")
local buf2 = yap.new()
assert(vim.b[buf2].yap_provider == "setup" and vim.b[buf2].yap_model == "m0", "session change leaked")

assert(yap.change_default_model == nil, "persistent default API still exists")
assert(yap.config.keymaps.change_default_model == nil, "persistent default keymap still exists")
yap.setup({ model_groups = { agent = "other/m1", flash = "" }})
local buf3 = yap.new()
assert(vim.b[buf3].yap_provider == "other" and vim.b[buf3].yap_model == "m1", "new group not applied")
assert(vim.b[buf2].yap_provider == "setup", "existing session was changed")
assert(vim.deep_equal(vim.fn.readfile(path), { "openai/old" }), "old cache file was modified")

for _, key in ipairs({ "provider", "model", "models" }) do
  local ok = pcall(yap.setup, { [key] = "obsolete" })
  assert(not ok, "obsolete setup key accepted: " .. key)
end
for _, role in ipairs({ "agent", "flash" }) do
  local ok = pcall(yap.setup, { model_groups = { [role] = "invalid"} })
  assert(not ok, "invalid " .. role .. " group accepted")
end
local ok_flash = pcall(yap.setup, { model_groups = { flash = "" } })
assert(ok_flash, "empty flash must disable titles and use agent for eval")
for _, role in ipairs({ "editor", "title" }) do
  local ok = pcall(yap.setup, { model_groups = { [role] = "mock/m1"} })
  assert(not ok, "obsolete group accepted: " .. role)
end
vim.system = system
print("OK default model")
