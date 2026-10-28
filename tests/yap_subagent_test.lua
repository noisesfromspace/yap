local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ model_groups = { agent = "mock/m1", flash = "" }})
local parent = yap.new()
local parent_path = vim.b[parent].yap_path
local name = require("harness.path").session_name(parent_path) .. "-abc123"
local child_path = vim.fn.fnamemodify(parent_path, ":h:h") .. "/" .. name .. "/session.md"
local child = yap.new({ hidden = true, path = child_path, agent = "scout", system = "Scout agent", tools = { "read" } })
assert(vim.api.nvim_get_current_buf() == parent, "child stole the parent window")
assert(vim.fn.filereadable(child_path) == 1, "child not saved as markdown")
assert(vim.b[child].yap_tools[1] == "read", "role tool allowlist missing")
local lines = vim.fn.readfile(child_path)
assert(table.concat(lines, "\n"):find("Scout agent", 1, true), "role prompt not saved")
-- An agent session is internal to the conversation that spawned it: saved
-- history never lists it, while the open-session picker still does.
for _, item in ipairs(require("harness.session").list("cwd")) do
  assert(item.path ~= child_path, "subagent session leaked into saved history")
end
local captured
vim.ui.select = function(items)
  captured = items
end
yap.instances()
local open_agent = false
for _, item in ipairs(captured or {}) do
  if item.buf == child then
    open_agent = true
  end
end
assert(open_agent, "open subagent missing from the instance picker")
yap.open(child_path)
assert(vim.b[vim.api.nvim_get_current_buf()].yap, "child not reopenable")
assert(vim.b[vim.api.nvim_get_current_buf()].yap_tools[1] == "read", "role permissions lost on reopen")
print("OK subagent session")
