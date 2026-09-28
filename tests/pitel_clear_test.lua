local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
pitel.setup({ bin = ROOT .. "/pitel" })
local buf = pitel.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system", "", "sys", "",
  "# @user", "", "do it", "",
  "# @assistant", "",
  '<!-- pitel:tool {"id":"b1","name":"bash","arguments":{"command":"ls"}} -->',
  "file1", "file2", "file3",
  "<!-- /pitel:tool -->", "",
  "Some text.", "",
  "<!-- pitel:tool",
  "{",
  '  "id": "w1",',
  '  "name": "write",',
  '  "arguments": { "path": "/tmp/x", "content": "big" }',
  "}",
  "-->",
  "Successfully wrote 3 bytes to /tmp/x",
  "<!-- pitel:ui",
  "+big",
  "-->",
  "<!-- /pitel:tool -->", "",
  "Done.", "",
  '<!-- pitel:tool {"id":"b2","name":"bash","arguments":{"command":"pwd"}} -->',
  "/tmp",
  "<!-- /pitel:tool -->", "",
  "All done.", "",
  "# @user", "",
})
pitel.clear(buf, 1)
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
-- the two older regions are cleared, the last one is kept
assert(not text:match("file1"), "old bash body not cleared")
assert(not text:match("Successfully wrote"), "old write body not cleared")
assert(select(2, text:gsub("%[output cleared", "")) == 2, "expected 2 placeholders: " .. text)
-- headers (the model's tool_calls history) and ui diffs survive
assert(text:match('"command":"ls"'), "header was cleared")
assert(text:match("%+big"), "ui diff was cleared")
assert(text:match("\n/tmp\n"), "last region should be kept: " .. text)
-- the context still parses: three tool results, two now the placeholder
local results = {}
for _, m in ipairs(pitel.parse_buffer(buf)) do
  if m.role == "tool" then
    table.insert(results, m.content)
  end
end
assert(#results == 3, "expected 3 tool results, got " .. #results)
assert(results[1]:match("^%[output cleared"), "result 1: " .. results[1])
assert(results[2]:match("^%[output cleared"), "result 2: " .. results[2])
assert(results[3] == "/tmp", "result 3: " .. results[3])
-- idempotent
pitel.clear(buf, 1)
assert(
  table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") == text,
  "second clear changed the buffer"
)
print("OK clear")
