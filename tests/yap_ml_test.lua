local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local document = require("harness.model.document")
local fold = require("harness.ui.fold")

local buf = yap.new({ provider = "mock", model = "m1" })
local lines = {
  "# @user",
  "",
  "write the file",
  "",
  "# @assistant",
  "",
  "<!-- yap:tool",
  "{",
  '  "id": "w1",',
  '  "name": "write",',
  '  "arguments": {',
  '    "content": "a\\nb",',
  '    "path": "/tmp/x.md"',
  "  }",
  "}",
  "-->",
  "Successfully wrote 2 bytes to /tmp/x.md",
  "<!-- yap:ui -->",
  "--- a//tmp/x.md",
  "+a",
  "+b",
  "<!-- /yap:ui -->",
  "<!-- /yap:tool -->",
  "",
  "File written.",
  "",
  "# @user",
  "",
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

-- parse: multi-line header flattens to tool name + JSON args + result
local msgs = document.parse_buffer(buf)
local asst
for _, m in ipairs(msgs) do
  if m.role == "assistant" then
    asst = m
  end
end
assert(asst and not asst.tool_calls, "no plain assistant message")
assert(asst.content:find("write", 1, true), "tool name missing: " .. asst.content)
assert(asst.content:find('"path":"/tmp/x.md"', 1, true), "arguments mangled: " .. asst.content)
assert(asst.content:find('"content":"a\\nb"', 1, true), "multi-line argument mangled: " .. asst.content)
assert(asst.content:match("Successfully wrote"), "result wrong: " .. asst.content)
assert(not asst.content:match("yap:ui") and not asst.content:match("%+a"), "ui leaked into result")
assert(not asst.content:match('"id"'), "header json leaked into result")
assert(asst.content:match("File written"), "answer after region lost: " .. asst.content)

-- folds: the whole tool region (header, result, ui, closer) is one
-- level-3 fold
fold.setup_buffer(buf)
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)
local fc = vim.fn.foldclosed
assert(fc(7) == 7, "opener not folded: " .. fc(7))
assert(fc(10) == 7, "json interior outside fold: " .. fc(10))
assert(fc(16) == 7, "--> closer outside fold: " .. fc(16))
assert(fc(17) == 7, "result outside fold: " .. fc(17))
assert(fc(18) == 7, "ui marker outside fold: " .. fc(18))
assert(fc(23) == 7, "/yap:tool closer outside fold: " .. fc(23))
assert(fc(25) == -1, "answer after region should be unfolded: " .. fc(25))

-- view 2: assistant open, the whole tool region folded as one
fold.set_view_level(2)
assert(vim.fn.foldclosed(5) == -1, "view 2 folds assistant block")
assert(vim.fn.foldclosed(7) == 7, "view 2 leaves tool region open")
assert(vim.fn.foldclosed(17) == 7, "result not folded with the region")
assert(vim.fn.foldclosed(18) == 7, "ui not folded with the region")
assert(vim.fn.foldclosed(23) == 7, "closer not folded with the region")
local text = fold.text(7, 23)
assert(text:match("tool: write"), "foldtext: " .. text)
print("OK")
