local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
local fold = require("harness.fold")
local buf = pitel.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user", "", "write it", "",
  "# @assistant", "",
  '<!-- pitel:tool {"id":"w1","name":"write","arguments":{"path":"/tmp/x.md","content":"[2 lines]"}} -->',
  "Successfully wrote 2 bytes to /tmp/x.md",
  "<!-- pitel:ui -->",
  "```diff",
  "--- a//tmp/x.md",
  "+++ b//tmp/x.md",
  "@@ -1,0 +1,2 @@",
  "+a",
  "+b",
  "```",
  "<!-- /pitel:ui -->",
  "<!-- /pitel:tool -->",
  "",
  "File written.", "",
  "# @user", "",
})
-- parse: the paired ui diff is excluded from the tool result
local toolmsg
for _, m in ipairs(pitel.parse_buffer(buf)) do
  if m.role == "tool" then toolmsg = m end
end
assert(toolmsg and toolmsg.tool_call_id == "w1", "no tool result")
assert(toolmsg.content:match("Successfully wrote"), "result missing: " .. tostring(toolmsg.content))
assert(not toolmsg.content:match("pitel:ui") and not toolmsg.content:match("%+a"), "ui leaked into result")

-- folds: the paired ui region is part of the one level-3 tool fold
fold.setup_buffer(buf)
vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
local function lvl(l) return vim.fn.foldlevel(l) end
assert(lvl(7) == 3, "opener level: " .. lvl(7))
assert(lvl(9) == 3, "ui marker level: " .. lvl(9))
assert(lvl(10) == 3, "fence level: " .. lvl(10))
assert(lvl(16) == 3, "fence close level: " .. lvl(16))
assert(lvl(17) == 3, "/pitel:ui level: " .. lvl(17))
assert(lvl(18) == 3, "/pitel:tool level: " .. lvl(18))
assert(lvl(20) == 2, "answer level: " .. lvl(20))
print("OK uidiff")
