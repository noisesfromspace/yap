local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })
local buf = yap.new()
-- the tail sidecar file is created with the session, before any tool runs
local tail_path = vim.b[buf].yap_tail_path
assert(tail_path and vim.fn.filereadable(tail_path) == 1, "tail file not created up front: " .. tostring(tail_path))
-- :YapLive opens the tail even before any tool has run (empty, fills
-- later as tools execute)
yap.live()
assert(
  vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):match("%-tail$"),
  "live did not open the tail buffer"
)
assert(vim.api.nvim_buf_line_count(0) == 1, "fresh tail should have a single empty line")
-- the chat buffer is untouched and still parseable
assert(#yap.parse_buffer(buf) == 1, "chat buffer changed")
print("OK live-open")
