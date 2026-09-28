local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
pitel.setup({ bin = ROOT .. "/pitel" })
local buf = pitel.new()
-- :PitelLive opens the tail even before any tool has run (empty, fills
-- later as tools execute)
pitel.live()
assert(
  vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):match("%-tail$"),
  "live did not open the tail buffer"
)
assert(vim.api.nvim_buf_line_count(0) == 1, "fresh tail should have a single empty line")
-- the chat buffer is untouched and still parseable
assert(#pitel.parse_buffer(buf) == 1, "chat buffer changed")
print("OK live-open")
