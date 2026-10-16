local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
package.loaded.harness = nil
local yap = require("harness")
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
