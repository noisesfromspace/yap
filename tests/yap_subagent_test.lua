local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ provider = "mock", model = "m1" })
local parent = yap.new()
local parent_path = vim.b[parent].yap_path
local child_path = parent_path:gsub("%.md$", "") .. "-abc123.md"
local child = yap.new({ hidden = true, path = child_path, role = "scout", system = "Scout role", tools = { "read" } })
assert(vim.api.nvim_get_current_buf() == parent, "child stole the parent window")
assert(vim.fn.filereadable(child_path) == 1, "child not saved as markdown")
assert(vim.b[child].yap_tools[1] == "read", "role tool allowlist missing")
local lines = vim.fn.readfile(child_path)
assert(table.concat(lines, "\n"):find("Scout role", 1, true), "role prompt not saved")
local found = false
for _, item in ipairs(require("harness.session").list("cwd")) do
  if item.path == child_path then found = true end
end
assert(not found, "subagent child must be hidden from the session history")
yap.open(child_path)
assert(vim.b[vim.api.nvim_get_current_buf()].yap, "child not reopenable")
assert(vim.b[vim.api.nvim_get_current_buf()].yap_tools[1] == "read", "role permissions lost on reopen")
print("OK subagent session")
