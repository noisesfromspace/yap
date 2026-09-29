local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user", "", "Weather in Amsterdam?", "",
  "# @assistant", "",
  "Let me check.", "",
  '<!-- yap:tool {"id":"call_1","name":"get_weather","arguments":{"city":"Amsterdam"}} -->',
  "Weather in Amsterdam: 18 degrees, sunny",
  "<!-- yap:ui", "```", "Amsterdam: 18C", "```", "-->",
  "<!-- /yap:tool -->", "",
  "It is 18 degrees and sunny in Amsterdam.", "",
  "# @user", "",
})
local msgs = yap.parse_buffer(buf)
assert(#msgs == 3, "expected 3 messages, got " .. #msgs .. ": " .. vim.inspect(msgs))
local a, t = msgs[2], msgs[3]
assert(a.role == "assistant" and a.tool_calls, "msg 2 not tool-bearing assistant")
assert(a.content:match("Let me check") and a.content:match("18 degrees and sunny"), "assistant text wrong: " .. a.content)
assert(not a.content:match("yap:tool") and not a.content:match("yap:ui"), "markers leaked into content")
local c = a.tool_calls[1]
assert(c.id == "call_1" and c.type == "function", "wire call shape wrong")
assert(c["function"].name == "get_weather", "name wrong")
assert(vim.json.decode(c["function"].arguments).city == "Amsterdam", "arguments not a JSON string: " .. c["function"].arguments)
assert(t.role == "tool" and t.tool_call_id == "call_1", "tool message wrong")
assert(t.content == "Weather in Amsterdam: 18 degrees, sunny", "result wrong: " .. t.content)
assert(not t.content:match("Amsterdam: 18C"), "yap:ui leaked into result")

-- sanitizer: deleting the region removes the pair
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user", "", "hi", "",
  "# @assistant", "", "plain answer", "",
  "# @user", "",
})
local m2 = yap.parse_buffer(buf)
assert(#m2 == 2 and m2[2].content == "plain answer" and not m2[2].tool_calls, "delete-region case broken")

-- sanitizer: region inside a user block is skipped
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user", "", "question", "",
  '<!-- yap:tool {"id":"x","name":"y","arguments":{}} -->', "junk", "<!-- /yap:tool -->", "",
  "# @assistant", "", "answer", "",
})
local m3 = yap.parse_buffer(buf)
assert(#m3 == 2, "user-block tool region not skipped: " .. vim.inspect(m3))

-- sanitizer: missing result -> empty result, still paired
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @assistant", "",
  '<!-- yap:tool {"id":"c9","name":"noop","arguments":{}} -->',
  "<!-- /yap:tool -->", "",
})
local m4 = yap.parse_buffer(buf)
assert(#m4 == 2 and m4[2].role == "tool" and m4[2].content == "", "empty result not paired: " .. vim.inspect(m4))
print("OK")
