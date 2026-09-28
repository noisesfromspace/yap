local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
local fold = require("harness.fold")
local buf = pitel.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user", "", "cat the session", "",
  "# @assistant", "",
  '<!-- pitel:tool {"id":"b1","name":"bash","arguments":{"command":"cat x"}} -->',
  "```",
  "===== repro.md =====",
  "# @system",      -- inside the fence: literal content, NOT a heading
  "sys text",
  "# @user",
  "more",
  "```python",      -- nested fence inside: literal (info string -> not a closer)
  "print('x')",
  "```",
  "<!-- /pitel:tool -->",
  "",
  "File written.", "",
  "# @user", "",
})
fold.setup_buffer(buf)
vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
local function lvl(l) return vim.fn.foldlevel(l) end
assert(lvl(7) == 2, "opener: " .. lvl(7))
assert(lvl(8) == 2, "fence open: " .. lvl(8))
assert(lvl(10) == 2, "# @system inside fence: " .. lvl(10))
assert(lvl(12) == 2, "# @user inside fence: " .. lvl(12))
assert(lvl(13) == 2, "nested fence: " .. lvl(13))
assert(lvl(15) == 2, "closer: " .. lvl(15))
assert(lvl(16) == 2, "/pitel:tool: " .. lvl(16))
assert(lvl(18) == 1, "answer: " .. lvl(18))
assert(lvl(20) == 1, "next user: " .. lvl(20))
print("OK fencefold")
