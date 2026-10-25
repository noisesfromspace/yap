-- Renaming a session means renaming its directory: the audit log and notes
-- move with the directory (they live inside it), while the display name comes
-- from the frontmatter title, not the directory name.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local buf = yap.new()
yap.send()
local ok = vim.wait(10000, function()
  return text(buf):match("File written%.") ~= nil
end, 100)
assert(ok, "first send did not complete")
vim.wait(300) -- let the turn-end save and description settle

local paths = require("harness.path")
local old = vim.b[buf].yap_path
local old_dir = vim.fn.fnamemodify(old, ":h")
assert(vim.fn.filereadable(paths.audit_path(buf)) == 1, "audit log not written")

-- Give the session an explicit title before it moves (typed into the
-- always-present empty `title:` line).
local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
for i, l in ipairs(buf_lines) do
  if l:match("^title:") then
    vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { "title: My titled session" })
    break
  end
end
require("harness.session").save(buf)

-- Close the buffer so no later save re-points it at the stale path.
vim.cmd("bwipeout!")

-- Rename the session directory; history derives the name from the directory.
local project = vim.fn.fnamemodify(old, ":h:h")
local new_dir = project .. "/renamed-session"
assert(vim.fn.rename(old_dir, new_dir) == 0, "directory rename failed")
local new = new_dir .. "/session.md"
assert(vim.fn.filereadable(new) == 1, "session.md missing after rename")

-- The audit log and notes move with the directory.
assert(vim.fn.filereadable(new_dir .. "/audit.jsonl") == 1, "audit log did not follow the directory")
assert(vim.fn.filereadable(old_dir .. "/audit.jsonl") == 0, "old audit log left behind")

-- History shows the session under its title, not the directory name.
local found
for _, item in ipairs(require("harness.session").list("cwd")) do
  if item.path == new then
    found = item
  end
end
assert(found and found.text == "My titled session", "titled session missing or mislabeled: " .. vim.inspect(found))

print("OK audit-rename")
