-- A session buffer is the source of truth. When the session file changes
-- outside the buffer (a second writer, a stale disk copy), Neovim must not
-- reload it from disk or prompt about the divergence: the in-memory text
-- stays, and the next save re-serializes it. Regression for the
-- FileChangedShell guard in setup().
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

local buf = yap.new()
local path = vim.b[buf].yap_path
assert(path and vim.fn.filereadable(path) == 1, "session not saved")

-- The user's in-memory text diverges from the file on disk.
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "typed text" })
assert(vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "typed text"))

-- An external writer overwrites the file behind the buffer's back.
vim.fn.writefile({ "external change" }, path)

-- A file-changed check would normally prompt (or reload) here.
vim.cmd("checktime")

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(vim.tbl_contains(lines, "typed text"), "session buffer was reloaded from disk")
assert(not vim.tbl_contains(lines, "external change"), "external content leaked into the buffer")

print("OK fcs guard")
