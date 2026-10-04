local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local fold = require("harness.fold")
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
local function lvl(l)
  return vim.fn.foldlevel(l)
end
assert(lvl(7) == 3, "opener: " .. lvl(7))
assert(lvl(8) == 3, "fence open: " .. lvl(8))
assert(lvl(10) == 3, "# @system inside fence: " .. lvl(10))
assert(lvl(12) == 3, "# @user inside fence: " .. lvl(12))
assert(lvl(13) == 3, "nested fence: " .. lvl(13))
assert(lvl(15) == 3, "closer: " .. lvl(15))
assert(lvl(16) == 3, "/yap:tool: " .. lvl(16))
assert(lvl(18) == 2, "answer: " .. lvl(18))
assert(lvl(20) == 2, "next user: " .. lvl(20))
print("OK fencefold")
