local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })
local buf = yap.new()
local chat_win = vim.api.nvim_get_current_win()
-- :YapLive opens the audit view even before any tool has run (empty, fills
-- later as tools execute)
yap.live()
local audit = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(audit):match("%-audit$"), "live did not open the audit view buffer")
assert(not vim.bo[audit].modifiable, "fresh audit view should be read-only")
assert(
  vim.api.nvim_buf_get_lines(audit, 0, 1, false)[1]:match("^Audit · "),
  "fresh audit view missing header"
)
assert(vim.fn.maparg("<leader>l", "n", false, true).buffer == 1, "audit view has no buffer-local live toggle")
yap.live(audit)
assert(#vim.fn.win_findbuf(audit) == 0, "live from audit view did not close it")
vim.api.nvim_set_current_win(chat_win)
yap.live()
assert(#vim.fn.win_findbuf(audit) == 1, "live did not reopen audit view")
vim.api.nvim_set_current_win(chat_win)
yap.live()
assert(#vim.fn.win_findbuf(audit) == 0, "live from chat did not toggle visible audit view closed")
-- the session buffer is untouched and still parseable
assert(#yap.parse_buffer(buf) == 1, "session buffer changed")

-- The audit view is a drawer too: under the session's own column, and
-- closing it from the chat refocuses the session window.
vim.cmd("vsplit")
vim.api.nvim_set_current_win(chat_win)
yap.live()
assert(vim.api.nvim_get_current_buf() == audit, "audit view did not reopen beside the vertical split")
assert(
  vim.api.nvim_win_get_width(0) == vim.api.nvim_win_get_width(chat_win),
  "audit view drawer is not under the session column: " .. vim.api.nvim_win_get_width(0) .. " vs " .. vim.api.nvim_win_get_width(chat_win)
)
assert(
  vim.api.nvim_win_get_position(0)[2] == vim.api.nvim_win_get_position(chat_win)[2],
  "audit view drawer is not aligned with the session column"
)
vim.api.nvim_set_current_win(chat_win)
yap.live()
assert(#vim.fn.win_findbuf(audit) == 0, "audit view did not close from the vertical split")
assert(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) == buf, "closing audit view did not refocus the chat")
print("OK live-open")
