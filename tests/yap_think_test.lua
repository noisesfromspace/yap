local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local document = require("harness.model.document")
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
local msgs = document.parse_buffer(buf)
assert(#msgs == 2, "expected 2 messages, got " .. #msgs)
assert(msgs[2].role == "assistant", "msg 2 should be assistant")
assert(msgs[2].content == "The answer is 42.", "thinking leaked into content: " .. vim.inspect(msgs[2].content))
print("parse clean: " .. vim.inspect(msgs[2].content))

-- An unclosed thinking comment must be bounded at the next message heading
-- instead of swallowing the rest of the buffer (R-buffer-only-state).
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user",
  "",
  "q",
  "",
  "# @assistant",
  "",
  "intro",
  "",
  "<!-- yap:thinking",
  "unclosed reasoning",
  "# @user",
  "",
  "next question",
  "",
})
local m2 = document.parse_buffer(buf)
assert(#m2 == 3, "unclosed thinking swallowed messages: " .. vim.inspect(m2))
assert(m2[2].role == "assistant" and m2[2].content == "intro", "assistant intro lost: " .. vim.inspect(m2[2]))
assert(m2[3].role == "user" and m2[3].content == "next question", "user message lost: " .. vim.inspect(m2[3]))

-- structure.parse must see through an unclosed thinking comment to the
-- headings on the other side (document.parse_buffer relies on it).
local structure = require("harness.model.structure")
local p = structure.parse(buf)
assert(#p.headings == 3, "expected 3 headings, got " .. #p.headings .. ": " .. vim.inspect(p.headings))
assert(p.regions[1].kind == "thinking" and p.regions[1].finish == 10, "thinking region not bounded: " .. vim.inspect(p.regions))

-- A marker escaped by the backend (\<!-- yap:...) at line start is prose,
-- not a tool region (the unescaped form would be skipped as an orphan).
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @assistant",
  "",
  "\\<!-- yap:tool --> is quoted prose",
  "",
  "# @user",
  "",
})
local m3 = document.parse_buffer(buf)
assert(#m3 == 1, "escaped marker split messages: " .. vim.inspect(m3))
assert(m3[1].content:find("<!-- yap:tool", 1, true), "escaped marker text lost")
print("OK")
