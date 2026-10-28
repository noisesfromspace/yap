-- A `:file`/`:saveas` rename names the transcript without re-rooting the
-- session into the current working directory: save() keeps its basename in
-- the session directory, so the write stays there and the project directory's
-- permissions are untouched.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})

-- Run from a throwaway project directory so its permissions are what we
-- assert on (a concurrent test must never chmod the repo root).
local project = vim.fn.tempname()
vim.fn.mkdir(project, "p")
vim.cmd("cd " .. vim.fn.fnameescape(project))

local buf = yap.new()
local session_path = vim.b[buf].yap_path
local session_dir = vim.fn.fnamemodify(session_path, ":h")
local before_perm = vim.fn.getfperm(project)

-- A `:file` rename re-roots into the session directory, keeping the new
-- basename as the session title, and never writes into the project cwd.
vim.cmd("file my-title.md")
require("harness.session").save(buf)
local renamed = session_dir .. "/my-title.md"
assert(vim.b[buf].yap_path == renamed, "save() did not keep the renamed basename")
assert(vim.api.nvim_buf_get_name(buf) == renamed, "buffer name not re-pointed to the renamed transcript")
assert(vim.fn.filereadable(renamed) == 1, "renamed transcript not written")
assert(vim.fn.filereadable(session_path) == 0, "stale session.md left behind")
assert(vim.fn.getfperm(project) == before_perm, "project directory permissions changed after :file")
assert(require("harness.session").file_title(renamed) == "my-title", "filename title missing")

-- :saveas also re-roots into the session directory, keeping the basename.
local copy_target = vim.fn.tempname() .. ".md"
vim.cmd("saveas " .. vim.fn.fnameescape(copy_target))
require("harness.session").save(buf)
vim.fn.delete(copy_target)
local saveas_renamed = session_dir .. "/" .. vim.fn.fnamemodify(copy_target, ":t")
assert(vim.api.nvim_buf_get_name(buf) == saveas_renamed, ":saveas re-rooted the session")
assert(vim.fn.getfperm(project) == before_perm, "project directory permissions changed after :saveas")

print("OK saveas-guard")
