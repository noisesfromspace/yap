local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("pitel")
local buf = pitel.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @assistant", "",
  "<!-- pitel:thinking",
  "reasoning line",
  "-- >", -- escaped bare arrow: stays inside the marker
  "more reasoning",
  "-->",
  "",
  "<!-- pitel:tool {\"id\":\"c1\",\"name\":\"bash\",\"arguments\":{\"command\":\"x\"}} -->",
  "result",
  "<!-- pitel:ui",
  " context",
  "+-->", -- diff lines CONTAINING --> must not close early
  " -->",
  "+after",
  "-->",
  "<!-- /pitel:tool -->",
  "",
  "answer", "",
  "# @user", "",
})
local toolmsg
for _, m in ipairs(pitel.parse_buffer(buf)) do
  if m.role == "tool" then toolmsg = m end
end
assert(toolmsg, "no tool message")
assert(toolmsg.content:match("result"), "result missing")
assert(not toolmsg.content:match("%+after"), "ui leaked into result after early close")
assert(not toolmsg.content:match("%-%- >"), "ui content leaked")
print("OK markers")
