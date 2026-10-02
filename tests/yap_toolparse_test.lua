local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user",
  "",
  "Weather in Amsterdam?",
  "",
  "# @assistant",
  "",
  "Let me check.",
  "",
  '<!-- yap:tool {"id":"call_1","name":"get_weather","arguments":{"city":"Amsterdam"}} -->',
  "Weather in Amsterdam: 18 degrees, sunny",
  "<!-- yap:ui",
  "```",
  "Amsterdam: 18C",
  "```",
  "-->",
  "<!-- /yap:tool -->",
  "",
  "It is 18 degrees and sunny in Amsterdam.",
  "",
  "# @user",
  "",
})
local msgs = yap.parse_buffer(buf)
assert(#msgs == 2, "expected 2 messages, got " .. #msgs .. ": " .. vim.inspect(msgs))
local a = msgs[2]
assert(a.role == "assistant" and not a.tool_calls, "msg 2 not a plain assistant message")
assert(
  a.content:match("Let me check") and a.content:match("18 degrees and sunny"),
  "assistant text wrong: " .. a.content
)
-- the tool region is flattened into ordinary transcript text: tool name,
-- JSON arguments, and result — no native tool_calls/tool roles.
assert(a.content:find("get_weather", 1, true), "tool name missing: " .. a.content)
assert(a.content:find('"city":"Amsterdam"', 1, true), "tool arguments missing: " .. a.content)
assert(a.content:find("Weather in Amsterdam: 18 degrees, sunny", 1, true), "tool result missing: " .. a.content)
assert(not a.content:match("yap:tool") and not a.content:match("yap:ui"), "markers leaked into content")
assert(not a.content:match("Amsterdam: 18C"), "yap:ui leaked into result")

-- sanitizer: deleting the region removes the pair
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user",
  "",
  "hi",
  "",
  "# @assistant",
  "",
  "plain answer",
  "",
  "# @user",
  "",
})
local m2 = yap.parse_buffer(buf)
assert(#m2 == 2 and m2[2].content == "plain answer" and not m2[2].tool_calls, "delete-region case broken")

-- sanitizer: region inside a user block is skipped
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user",
  "",
  "question",
  "",
  '<!-- yap:tool {"id":"x","name":"y","arguments":{}} -->',
  "junk",
  "<!-- /yap:tool -->",
  "",
  "# @assistant",
  "",
  "answer",
  "",
})
local m3 = yap.parse_buffer(buf)
assert(#m3 == 2, "user-block tool region not skipped: " .. vim.inspect(m3))

-- sanitizer: missing result -> empty labelled result in the transcript
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @assistant",
  "",
  '<!-- yap:tool {"id":"c9","name":"noop","arguments":{}} -->',
  "<!-- /yap:tool -->",
  "",
})
local m4 = yap.parse_buffer(buf)
assert(
  #m4 == 1 and m4[1].role == "assistant" and m4[1].content == "Tool call: noop\nArguments: {}\nTool result:",
  "empty result not flattened: " .. vim.inspect(m4)
)
print("OK")
