local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system",
  "",
  "sys",
  "",
  "# @user",
  "",
  "do it",
  "",
  "# @assistant",
  "",
  '<!-- yap:tool {"id":"b1","name":"bash","arguments":{"command":"ls"}} -->',
  "file1",
  "file2",
  "file3",
  "<!-- /yap:tool -->",
  "",
  "Some text.",
  "",
  "<!-- yap:tool",
  "{",
  '  "id": "w1",',
  '  "name": "write",',
  '  "arguments": { "path": "/tmp/x", "content": "big" }',
  "}",
  "-->",
  "Successfully wrote 3 bytes to /tmp/x",
  "<!-- yap:ui",
  "+big",
  "-->",
  "<!-- /yap:tool -->",
  "",
  "Done.",
  "",
  '<!-- yap:tool {"id":"b2","name":"bash","arguments":{"command":"pwd"}} -->',
  "/tmp",
  "<!-- /yap:tool -->",
  "",
  "All done.",
  "",
  "# @user",
  "",
})
local notices = {}
local notify = vim.notify
vim.notify = function(msg) notices[#notices + 1] = msg end
yap.clear(buf, 1)
vim.notify = notify
assert(#notices == 0, "successful clear should not notify: " .. table.concat(notices, " | "))
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
-- the two older regions are cleared, the last one is kept
assert(not text:match("file1"), "old bash body not cleared")
assert(not text:match("Successfully wrote"), "old write body not cleared")
assert(select(2, text:gsub("%[output cleared", "")) == 2, "expected 2 placeholders: " .. text)
-- headers (flattened call transcript) and ui diffs survive
assert(text:match('"command":"ls"'), "header was cleared")
assert(text:match("%+big"), "ui diff was cleared")
assert(text:match("\n/tmp\n"), "last region should be kept: " .. text)
-- placeholders carry an exact audit-log path (file.jsonl:line[-line]); the
-- audit log is absent here, so they fall back to the path with a '?' line
assert(text:match("%.jsonl:%?%]"), "placeholder missing audit path: " .. text)
-- the context still parses: three tool regions flattened into one assistant
-- transcript; the two cleared bodies are the placeholder, the last is /tmp
local asst
for _, m in ipairs(yap.parse_buffer(buf)) do
  if m.role == "assistant" then
    asst = m
  end
end
assert(asst, "no assistant message after clear")
assert(select(2, asst.content:gsub("%[output cleared", "")) == 2, "expected 2 placeholders: " .. asst.content)
assert(asst.content:match("\n/tmp\n") or asst.content:match("^/tmp\n"), "last region result kept: " .. asst.content)
-- idempotent
vim.notify = function(msg) notices[#notices + 1] = msg end
yap.clear(buf, 1)
vim.notify = notify
assert(#notices == 0, "idempotent clear should not notify: " .. table.concat(notices, " | "))
assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") == text, "second clear changed the buffer")
print("OK clear")
