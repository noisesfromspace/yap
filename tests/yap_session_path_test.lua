local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local paths = require("harness.path")
local dir = paths.session_dir(vim.fn.getcwd())
local month = os.date("%y-%m")
local day = os.date("%d")
local base = dir .. "/" .. month

-- Existing sessions keep their old paths and remain discoverable.
local old = base .. "/" .. day .. "-08.24.34"
paths.ensure_session_dir(old)
vim.fn.writefile({ "# @user", "old session" }, old .. "/session.md")
local first = paths.new_session_path(dir)
assert(first == base .. "/" .. day .. "-001/session.md", first)
vim.fn.writefile({ "# @user", "new session" }, first)
local second = paths.new_session_path(dir)
assert(second == base .. "/" .. day .. "-002/session.md", second)

local names = {}
for _, sdir in ipairs(paths.session_dirs(dir)) do
  names[sdir] = true
end
assert(names[old] and names[vim.fn.fnamemodify(first, ":h")], "old/new sessions not discovered")
assert(vim.fn.readfile(old .. "/session.md")[2] == "old session", "legacy transcript changed")

-- Skipped numbers must not be reused, and named/legacy directories do not
-- affect today's counter. Central data directories use the same scheme.
paths.ensure_session_dir(base .. "/" .. day .. "-007")
local next_path = paths.new_session_path(dir)
assert(next_path == base .. "/" .. day .. "-008/session.md", next_path)
local data = paths.new_data_dir(vim.fn.getcwd())
assert(data == base .. "/" .. day .. "-009", data)
assert(vim.fn.getfperm(data) == "rwx------", "data directory must be private")
assert(paths.child_session_dir(dir, old .. "/session.md") == base, "legacy child month changed")
assert(paths.child_session_dir(dir, first) == base, "new child month changed")
print("OK session path sequence")
