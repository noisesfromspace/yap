-- Hiding a session must persist its in-memory text. Neovim reloads an
-- unmodified, file-backed buffer from disk when it is re-entered; if that
-- file is stale (text typed but not yet saved), the reload silently drops
-- the text. Saving the buffer when it leaves every window (BufHidden) keeps
-- the file current, so re-entering is lossless even when 'modified' is false.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})

local buf = yap.new()
local path = vim.b[buf].yap_path
assert(path and vim.fn.filereadable(path) == 1, "session not saved")

vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "typed text" })
vim.bo[buf].modified = false -- simulate text that diverges from the file on disk

vim.cmd("enew") -- the session leaves its last window: BufHidden must save it
local disk = vim.fn.readfile(path)
assert(vim.tbl_contains(disk, "typed text"), "hiding the session did not persist its text")

vim.api.nvim_set_current_buf(buf)
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(vim.tbl_contains(lines, "typed text"), "re-entering the session lost the typed text")

print("OK hide save")
