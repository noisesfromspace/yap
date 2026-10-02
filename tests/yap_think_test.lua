local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user",
  "",
  "What is the answer?",
  "",
  "# @assistant",
  "",
  "<!-- yap:thinking",
  "Let me think about this.",
  "-->",
  "",
  "The answer is 42.",
  "",
  "# @user",
  "",
})
local msgs = yap.parse_buffer(buf)
assert(#msgs == 2, "expected 2 messages, got " .. #msgs)
assert(msgs[2].role == "assistant", "msg 2 should be assistant")
assert(msgs[2].content == "The answer is 42.", "thinking leaked into content: " .. vim.inspect(msgs[2].content))
print("parse clean: " .. vim.inspect(msgs[2].content))
print("OK")
