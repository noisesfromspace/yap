local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @assistant",
  "",
  "<!-- yap:thinking",
  "reasoning line",
  "-- >", -- escaped bare arrow: stays inside the marker
  "more reasoning",
  "-->",
  "",
  '<!-- yap:tool {"id":"c1","name":"bash","arguments":{"command":"x"}} -->',
  "result",
  "<!-- yap:ui",
  " context",
  "+-->", -- diff lines CONTAINING --> must not close early
  " -->",
  "+after",
  "-->",
  "<!-- /yap:tool -->",
  "",
  "answer",
  "",
  "# @user",
  "",
})
local asst
for _, m in ipairs(yap.parse_buffer(buf)) do
  if m.role == "assistant" then
    asst = m
  end
end
assert(asst, "no assistant message")
assert(asst.content:match("result"), "result missing")
assert(not asst.content:match("%+after"), "ui leaked into result after early close")
assert(not asst.content:match("%-%- >"), "ui content leaked")
print("OK markers")
