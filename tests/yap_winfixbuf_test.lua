-- Regression: opening a session (including a hidden subagent spawn) from a
-- window whose buffer is pinned with 'winfixbuf' (mini.files pins its
-- explorer window) must not raise E1513, and must leave a pinned window on
-- its original buffer.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ model_groups = { agent = "mock/m1", flash = "" }})

local win = vim.api.nvim_get_current_win()
local parent = vim.api.nvim_get_current_buf()
vim.wo[win].winfixbuf = true

local ok, child = pcall(yap.new, { hidden = true, agent = "scout", system = "Scout", tools = { "read" } })
assert(ok, "hidden new under winfixbuf failed: " .. tostring(child))
assert(vim.api.nvim_get_current_buf() == parent, "child stole the pinned window")
assert(vim.wo[win].winfixbuf == true, "winfixbuf not restored after hidden spawn")

local ok2, buf2 = pcall(yap.new)
assert(ok2, "visible new under winfixbuf failed: " .. tostring(buf2))
assert(vim.api.nvim_get_current_buf() == buf2, "visible new did not switch to the new session")

-- Resume a saved session (sessions() / yap.open) from a pinned window:
-- the loaded-but-unmodified buffer goes through :edit, which must not E1513.
local saved_path = vim.b[buf2].yap_path
vim.wo[win].winfixbuf = true
local ok3, resumed = pcall(yap.open, saved_path)
assert(ok3, "open under winfixbuf failed: " .. tostring(resumed))
assert(vim.api.nvim_get_current_buf() == resumed, "open did not switch to the resumed session")
assert(vim.wo[win].winfixbuf == true, "winfixbuf not restored after open")
print("OK winfixbuf spawn")
