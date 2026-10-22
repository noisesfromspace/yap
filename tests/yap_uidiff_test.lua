local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local document = require("harness.model.document")
local fold = require("harness.ui.fold")
local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user",
  "",
  "write it",
  "",
  "# @assistant",
  "",
  '<!-- yap:tool {"id":"w1","name":"write","arguments":{"path":"/tmp/x.md","content":"[2 lines]"}} -->',
  "Successfully wrote 2 bytes to /tmp/x.md",
  "<!-- yap:ui -->",
  "```diff",
  "--- a//tmp/x.md",
  "+++ b//tmp/x.md",
  "@@ -1,0 +1,2 @@",
  "+a",
  "+b",
  "```",
  "<!-- /yap:ui -->",
  "<!-- /yap:tool -->",
  "",
  "File written.",
  "",
  "# @user",
  "",
})
-- parse: the paired ui diff is excluded from the flattened tool region
local asst
for _, m in ipairs(document.parse_buffer(buf)) do
  if m.role == "assistant" then
    asst = m
  end
end
assert(asst, "no assistant message")
assert(asst.content:match("Successfully wrote"), "result missing: " .. tostring(asst.content))
assert(not asst.content:match("yap:ui") and not asst.content:match("%+a"), "ui leaked into result")

-- folds: the paired ui region is part of the one tool fold
fold.setup_buffer(buf)
vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
local fc = vim.fn.foldclosed
assert(fc(7) == 7, "opener not folded: " .. fc(7))
assert(fc(9) == 7, "ui marker outside fold: " .. fc(9))
assert(fc(10) == 7, "fence outside fold: " .. fc(10))
assert(fc(16) == 7, "fence close outside fold: " .. fc(16))
assert(fc(17) == 7, "/yap:ui outside fold: " .. fc(17))
assert(fc(18) == 7, "/yap:tool outside fold: " .. fc(18))
assert(fc(20) == -1, "answer should be unfolded: " .. fc(20))
print("OK uidiff")
