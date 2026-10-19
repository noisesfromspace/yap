local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local fold = require("harness.ui.fold")
local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user",
  "",
  "cat the session",
  "",
  "# @assistant",
  "",
  '<!-- yap:tool {"id":"b1","name":"bash","arguments":{"command":"cat x"}} -->',
  "```",
  "===== repro.md =====",
  "# @system", -- inside the fence: literal content, NOT a heading
  "sys text",
  "# @user",
  "more",
  "```python", -- nested fence inside: literal (info string -> not a closer)
  "print('x')",
  "```",
  "<!-- /yap:tool -->",
  "",
  "File written.",
  "",
  "# @user",
  "",
})
fold.setup_buffer(buf)
vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
local fc = vim.fn.foldclosed
assert(fc(7) == 7, "opener: " .. fc(7))
assert(fc(8) == 7, "fence open: " .. fc(8))
assert(fc(10) == 7, "# @system inside fence: " .. fc(10))
assert(fc(12) == 7, "# @user inside fence: " .. fc(12))
assert(fc(13) == 7, "nested fence: " .. fc(13))
assert(fc(15) == 7, "closer: " .. fc(15))
assert(fc(16) == 7, "/yap:tool: " .. fc(16))
assert(fc(18) == -1, "answer: " .. fc(18))
assert(fc(20) == -1, "next user: " .. fc(20))
print("OK fencefold")
