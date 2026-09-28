local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
local fold = require("harness.fold")

local buf = pitel.new({ provider = "mock", model = "m1" })
local lines = {
  "# @user", "", "write the file", "",
  "# @assistant", "",
  "<!-- pitel:tool",
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
  "<!-- pitel:ui",
  "--- a//tmp/x.md",
  "+a",
  "+b",
  "-->",
  "<!-- /pitel:tool -->",
  "",
  "File written.", "",
  "# @user", "",
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

-- parse: multi-line header becomes the same wire pair
local msgs = pitel.parse_buffer(buf)
local asst, toolmsg
for _, m in ipairs(msgs) do
  if m.role == "assistant" and m.tool_calls then asst = m end
  if m.role == "tool" then toolmsg = m end
end
assert(asst, "no tool_calls assistant message")
assert(asst.tool_calls[1].id == "w1" and asst.tool_calls[1]["function"].name == "write", "call wrong")
local args = vim.json.decode(asst.tool_calls[1]["function"].arguments)
assert(args.path == "/tmp/x.md" and args.content == "a\nb", "arguments mangled: " .. vim.inspect(args))
assert(toolmsg and toolmsg.tool_call_id == "w1", "no tool result")
assert(toolmsg.content:match("Successfully wrote"), "result wrong: " .. toolmsg.content)
assert(not toolmsg.content:match("pitel:ui") and not toolmsg.content:match("%+a"), "ui leaked into result")
assert(not toolmsg.content:match('"id"'), "header json leaked into result")

-- folds: the whole tool region (header, result, ui, closer) is one
-- level-2 fold
fold.setup_buffer(buf)
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)
local function lvl(l) return vim.fn.foldlevel(l) end
assert(lvl(7) == 2, "opener level: " .. lvl(7))
assert(lvl(10) == 2, "json interior level: " .. lvl(10))
assert(lvl(16) == 2, "--> closer level: " .. lvl(16))
assert(lvl(17) == 2, "result level: " .. lvl(17))
assert(lvl(18) == 2, "ui marker level: " .. lvl(18))
assert(lvl(23) == 2, "/pitel:tool closer level: " .. lvl(23))
assert(lvl(25) == 1, "answer after region level: " .. lvl(25))

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
