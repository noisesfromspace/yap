local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
package.loaded.harness = nil
local yap = require("harness")
assert(yap.config.model_groups.editor == "deepseek/deepseek-v4-pro", "editor group should default to the one-shot model")
yap.setup({
  bin = ROOT .. "/yap",
  model_groups = { editor = "mock/m1" },
  models = { "mock/m1" },
})

local eval = require("harness.client.eval")
local structure = require("harness.model.structure")

-- strip_markers removes the binary's thinking/model/error blocks but keeps
-- ordinary HTML comments untouched.
assert(
  structure.strip_markers("<!-- yap:thinking\nhidden\n-->\n\nout") == "\nout",
  "multi-line marker not stripped"
)
assert(structure.strip_markers("<!-- yap:model {} -->\nout") == "out", "single-line marker not stripped")
assert(structure.strip_markers("<!-- normal -->\nout") == "<!-- normal -->\nout", "non-yap comment stripped")

os.remove("/tmp/yap-eval.log")

-- Session buffer: the replacement is wrapped as one # @assistant message.
local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user", "question one", "# @assistant", "answer one",
  "# @user", "question two", "# @assistant", "answer two",
})
yap.eval({ buf = buf, line1 = 1, line2 = 8, instruction = "summarize these turns" })
local ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("summarized output") ~= nil
end, 100)
assert(ok, "session eval did not complete")
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(#lines == 4, "session eval replacement wrong length: " .. vim.inspect(lines))
assert(lines[1] == "# @assistant", "session eval did not wrap in # @assistant: " .. vim.inspect(lines))
assert(lines[2] == "", "session eval missing blank line after heading: " .. vim.inspect(lines))
assert(lines[3] == "summarized output", "session eval wrong body: " .. vim.inspect(lines))
assert(lines[4] == "", "session eval missing trailing blank line: " .. vim.inspect(lines))

-- Plain buffer: the replacement is plain text, no heading.
local plain = vim.api.nvim_create_buf(true, false)
vim.bo[plain].filetype = "go"
vim.api.nvim_buf_set_lines(plain, 0, -1, false, {
  "func add(a, b int) int {", "  return a + b", "}",
})
yap.eval({ buf = plain, line1 = 1, line2 = 3, instruction = "refactor this" })
ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(plain, 0, -1, false), "\n"):find("summarized output") ~= nil
end, 100)
assert(ok, "plain eval did not complete")
lines = vim.api.nvim_buf_get_lines(plain, 0, -1, false)
assert(#lines == 1 and lines[1] == "summarized output", "plain eval added a heading or wrong body: " .. vim.inspect(lines))

-- Selection with no instruction: the selection itself is the input, so it
-- applies a default transform instead of prompting (visual-mode :YapEval).
local implied = vim.api.nvim_create_buf(true, false)
vim.bo[implied].filetype = "go"
vim.api.nvim_buf_set_lines(implied, 0, -1, false, {
  "func add(a, b int) int {", "  return a + b", "}",
})
yap.eval({ buf = implied, line1 = 1, line2 = 3 })
ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(implied, 0, -1, false), "\n"):find("summarized output") ~= nil
end, 100)
assert(ok, "no-instruction eval did not complete")
lines = vim.api.nvim_buf_get_lines(implied, 0, -1, false)
assert(#lines == 1 and lines[1] == "summarized output", "no-instruction eval wrong body: " .. vim.inspect(lines))

-- Generate mode: no line range — the output is inserted at the cursor as new
-- lines (the "generate content into a fresh buffer" path).
local gen = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(gen)
vim.api.nvim_buf_set_lines(gen, 0, -1, false, { "before", "after" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
yap.eval({ buf = gen, instruction = "generate three addresses" })
ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(gen, 0, -1, false), "\n"):find("summarized output") ~= nil
end, 100)
assert(ok, "generate eval did not complete")
lines = vim.api.nvim_buf_get_lines(gen, 0, -1, false)
assert(#lines == 3, "generate eval wrong length: " .. vim.inspect(lines))
assert(lines[1] == "before", "generate eval clobbered earlier line: " .. vim.inspect(lines))
assert(lines[2] == "summarized output", "generate eval did not insert at cursor: " .. vim.inspect(lines))
assert(lines[3] == "after", "generate eval clobbered later line: " .. vim.inspect(lines))

-- :YapEval (no bang): an interactive, regular session in a split, listed in
-- :YapHistory. The selection is fenced context, nothing is sent without an
-- instruction, and the source buffer is left alone.
local src = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(src)
vim.bo[src].filetype = "go"
vim.api.nvim_buf_set_lines(src, 0, -1, false, { "a", "x := `y`", "c" })
local wins_before = #vim.api.nvim_tabpage_list_wins(0)
local sbuf = yap.eval_session({ buf = src, line1 = 2, line2 = 2 })
assert(#vim.api.nvim_tabpage_list_wins(0) == wins_before + 1, "eval session did not open a split")
assert(vim.api.nvim_get_current_buf() == sbuf, "focus did not move to the eval session")
assert(vim.b[sbuf].yap, "eval split is not a yap session")
assert(
  vim.deep_equal(vim.api.nvim_buf_get_lines(src, 0, -1, false), { "a", "x := `y`", "c" }),
  "eval session changed the source buffer"
)
local stext = table.concat(vim.api.nvim_buf_get_lines(sbuf, 0, -1, false), "\n")
assert(stext:find("\n```go\nx := `y`\n```\n\n$"), "selection not fenced at the end of the user turn: " .. stext)
assert(not stext:find("# @assistant"), "eval session sent without an instruction: " .. stext)
assert(not stext:find("return ONLY the result", 1, true), "eval session kept the one-shot system prompt")
local spath = vim.b[sbuf].yap_path
assert(spath and vim.fn.filereadable(spath) == 1, "eval session not saved: " .. tostring(spath))
local listed = false
for _, item in ipairs(require("harness.session").list()) do
  listed = listed or item.path == spath
end
assert(listed, "eval session missing from :YapHistory")

-- No tools were offered to the provider.
local log = io.open("/tmp/yap-eval.log", "r")
assert(log, "eval mock log missing")
local text = log:read("*a")
log:close()
for line in text:gmatch("[^\n]+") do
  local okj, req = pcall(vim.json.decode, line)
  if okj then
    assert(not (req.tools and type(req.tools) == "table" and #req.tools > 0), "eval offered tools: " .. line)
  end
end

print("OK eval")
