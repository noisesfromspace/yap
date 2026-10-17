local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
package.loaded.harness = nil
local yap = require("harness")
assert(yap.config.eval_model == "", "eval_model should default to inherit (empty)")
yap.setup({
  bin = ROOT .. "/yap",
  eval_model = "mock/m1",
  models = { "mock/m1" },
})

local eval = require("harness.eval")

-- strip_markers removes the binary's thinking/model/error blocks but keeps
-- ordinary HTML comments untouched.
assert(
  eval.strip_markers("<!-- yap:thinking\nhidden\n-->\n\nout") == "\nout",
  "multi-line marker not stripped"
)
assert(eval.strip_markers("<!-- yap:model {} -->\nout") == "out", "single-line marker not stripped")
assert(eval.strip_markers("<!-- normal -->\nout") == "<!-- normal -->\nout", "non-yap comment stripped")

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

-- show (:YapEval!): the response streams into a hidden eval session in a
-- split, and the marker-stripped answer still replaces the selection.
local shown = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(shown)
vim.api.nvim_buf_set_lines(shown, 0, -1, false, { "some text" })
local wins_before = #vim.api.nvim_tabpage_list_wins(0)
yap.eval({ buf = shown, line1 = 1, line2 = 1, instruction = "rewrite", show = true })
assert(#vim.api.nvim_tabpage_list_wins(0) == wins_before + 1, "show did not open a split")
assert(vim.api.nvim_get_current_buf() == shown, "show moved focus away from the source buffer")
ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(shown, 0, -1, false), "\n"):find("summarized output") ~= nil
end, 100)
assert(ok, "show eval did not complete")
lines = vim.api.nvim_buf_get_lines(shown, 0, -1, false)
assert(#lines == 1 and lines[1] == "summarized output", "show eval wrong body: " .. vim.inspect(lines))
local stream
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local b = vim.api.nvim_win_get_buf(w)
  if b ~= shown then
    stream = b
  end
end
local streamed = table.concat(vim.api.nvim_buf_get_lines(stream, 0, -1, false), "\n")
assert(streamed:find("summarized output"), "stream buffer missing output: " .. streamed)

-- The eval split is a real session: saved under the hidden .eval/ folder,
-- ending in a fresh # @user turn for follow-ups, and absent from the picker.
assert(vim.b[stream].yap, "eval split is not a yap session")
local spath = vim.b[stream].yap_path
assert(spath and spath:find("/%.eval/[^/]+/session%.md$"), "eval session not under .eval/: " .. tostring(spath))
assert(vim.fn.filereadable(spath) == 1, "eval session not saved: " .. spath)
assert(streamed:find("# @user\n*$"), "eval session missing trailing # @user: " .. streamed)
assert(require("harness.path").project_cwd(spath) == vim.fs.normalize(vim.fn.getcwd()), "eval session project_cwd wrong")
for _, item in ipairs(require("harness.session").list()) do
  assert(item.path ~= spath, "eval session listed in :YapSessions")
end

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
