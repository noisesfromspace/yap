-- Reopening a saved session that is already loaded and has unsaved changes
-- must reuse the live buffer instead of :edit (which raises E37 rather than
-- discard the changes).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})

local buf = yap.new()
local path = vim.b[buf].yap_path
assert(path and vim.fn.filereadable(path) == 1, "session not saved")
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "unsaved" })
assert(vim.bo[buf].modified, "buffer should be modified")

local ok, err = pcall(yap.open, path)
assert(ok, "open on a modified session raised: " .. tostring(err))
assert(vim.api.nvim_get_current_buf() == buf, "open did not focus the existing buffer")
assert(vim.bo[buf].modified, "unsaved changes were discarded")
assert(vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] == "unsaved", "unsaved line lost")

-- A loaded session whose 'modified' flag is false (while it still holds text
-- that diverges from the file on disk) must also be reused in place: `:edit`
-- would re-read the stale file and silently drop the in-memory text.
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "diverged" })
vim.bo[buf].modified = false
local ok2, err2 = pcall(yap.open, path)
assert(ok2, "open on an unmodified loaded session raised: " .. tostring(err2))
assert(vim.api.nvim_get_current_buf() == buf, "open did not reuse the loaded buffer")
assert(vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] == "diverged", "in-memory text lost to :edit")

print("OK open")
