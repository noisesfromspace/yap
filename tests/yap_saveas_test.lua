-- A `:file`/`:saveas` rename no longer re-roots a session into the current
-- working directory: save() re-points the buffer at its canonical
-- <dir>/session.md, so the write stays in the session directory and the
-- project directory's permissions are untouched.
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
local before_perm = vim.fn.getfperm(project)

vim.cmd("file stray-name.md")
require("harness.session").save(buf)
assert(vim.b[buf].yap_path == session_path, "save() re-rooted the session after :file")
assert(vim.api.nvim_buf_get_name(buf) == session_path, "buffer name not re-pointed to session.md")
assert(vim.fn.filereadable(session_path) == 1, "session.md not written")
assert(vim.fn.getfperm(project) == before_perm, "project directory permissions changed after :file")

-- :saveas also leaves the session put (save() re-points the buffer back).
local copy_target = vim.fn.tempname() .. ".md"
vim.cmd("saveas " .. vim.fn.fnameescape(copy_target))
require("harness.session").save(buf)
vim.fn.delete(copy_target)
assert(vim.api.nvim_buf_get_name(buf) == session_path, ":saveas re-rooted the session")
assert(vim.fn.getfperm(project) == before_perm, "project directory permissions changed after :saveas")

print("OK saveas-guard")
