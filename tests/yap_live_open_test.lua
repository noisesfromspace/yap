local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })
local buf = yap.new()
local chat_win = vim.api.nvim_get_current_win()
-- :YapLive opens the tail even before any tool has run (empty, fills
-- later as tools execute)
yap.live()
assert(
  vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):match("%-tail$"),
  "live did not open the tail buffer"
)
assert(vim.api.nvim_buf_line_count(0) == 1, "fresh tail should have a single empty line")
local tail = vim.api.nvim_get_current_buf()
assert(vim.fn.maparg("<leader>l", "n", false, true).buffer == 1, "tail has no buffer-local live toggle")
yap.live(tail)
assert(#vim.fn.win_findbuf(tail) == 0, "live from tail did not close it")
vim.api.nvim_set_current_win(chat_win)
yap.live()
assert(#vim.fn.win_findbuf(tail) == 1, "live did not reopen tail")
vim.api.nvim_set_current_win(chat_win)
yap.live()
assert(#vim.fn.win_findbuf(tail) == 0, "live from chat did not toggle visible tail closed")
-- the chat buffer is untouched and still parseable
assert(#yap.parse_buffer(buf) == 1, "chat buffer changed")
print("OK live-open")
