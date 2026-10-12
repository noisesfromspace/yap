local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })
local buf = yap.new()
local chat_win = vim.api.nvim_get_current_win()
-- :YapLive opens the live tool tail even before any tool has run (empty,
-- fills as tools execute)
yap.live()
local audit = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(audit):match("%-audit$"), "live did not open the tail buffer")
assert(not vim.bo[audit].modifiable, "fresh tail view should be read-only")
assert(
  vim.api.nvim_win_get_height(0) == math.max(1, math.floor(vim.o.lines / 2)),
  "tail drawer is not half the screen: " .. vim.api.nvim_win_get_height(0) .. " vs " .. math.floor(vim.o.lines / 2)
)
assert(vim.fn.maparg("<leader>l", "n", false, true).buffer == 1, "tail view has no buffer-local live toggle")
yap.live(audit)
assert(#vim.fn.win_findbuf(audit) == 0, "live from tail view did not close it")
vim.api.nvim_set_current_win(chat_win)
yap.live()
assert(#vim.fn.win_findbuf(audit) == 1, "live did not reopen tail view")
vim.api.nvim_set_current_win(chat_win)
yap.live()
assert(#vim.fn.win_findbuf(audit) == 0, "live from chat did not toggle visible tail view closed")
-- the session buffer is untouched and still parseable
assert(#yap.parse_buffer(buf) == 1, "session buffer changed")

-- The tail view is a drawer too: under the session's own column, and
-- closing it from the chat refocuses the session window.
vim.cmd("vsplit")
vim.api.nvim_set_current_win(chat_win)
yap.live()
assert(vim.api.nvim_get_current_buf() == audit, "tail view did not reopen beside the vertical split")
assert(
  vim.api.nvim_win_get_width(0) == vim.api.nvim_win_get_width(chat_win),
  "tail view drawer is not under the session column: " .. vim.api.nvim_win_get_width(0) .. " vs " .. vim.api.nvim_win_get_width(chat_win)
)
assert(
  vim.api.nvim_win_get_position(0)[2] == vim.api.nvim_win_get_position(chat_win)[2],
  "tail view drawer is not aligned with the session column"
)
vim.api.nvim_set_current_win(chat_win)
yap.live()
assert(#vim.fn.win_findbuf(audit) == 0, "tail view did not close from the vertical split")
assert(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) == buf, "closing tail view did not refocus the chat")
print("OK live-open")
