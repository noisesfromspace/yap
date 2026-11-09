local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
package.loaded.harness = nil
local yap = require("harness")
assert(yap.config.model_groups.agent == "openai/gpt-6.1-sol", "agent default")
assert(yap.config.model_groups.flash == "deepseek/deepseek-flash", "flash default")
yap.setup({
  bin = ROOT .. "/yap",
  model_groups = { agent = "mock/m1", flash = "mock/flash" },
})

local eval = require("harness.client.eval")
assert(select(2, eval.combo()) == "flash", "one-shot eval should use flash")
local structure = require("harness.model.structure")
local fold = require("harness.ui.fold")

-- strip_markers removes the binary's thinking/model/error blocks but keeps
-- ordinary HTML comments untouched.
assert(
  structure.strip_markers("<!-- yap:thinking\nhidden\n-->\n\nout") == "\nout",
  "multi-line marker not stripped"
)
assert(structure.strip_markers("<!-- yap:model {} -->\nout") == "out", "single-line marker not stripped")
assert(structure.strip_markers("<!-- normal -->\nout") == "<!-- normal -->\nout", "non-yap comment stripped")
-- A closer with trailing whitespace must still close the marker (the buffer
-- scanner tolerates it; the raw-output counterpart must match).
assert(
  structure.strip_markers("<!-- yap:thinking\nhidden\n--> \n\nout") == "\nout",
  "marker closer with trailing space not stripped"
)

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
-- sessions(). The selection is fenced context, nothing is sent without an
-- instruction, and the source buffer is left alone.
local src = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(src)
vim.bo[src].filetype = "go"
vim.api.nvim_buf_set_lines(src, 0, -1, false, { "a", "x := `y`", "c" })
vim.api.nvim_buf_set_name(src, vim.fn.tempname() .. ".go")
local session = require("harness.session")
local function is_listed(path)
  for _, item in ipairs(session.list()) do
    if item.path == path then
      return true
    end
  end
  return false
end

-- A file-only eval is just scaffolding, not a prompt. It stays hidden even
-- while loaded; typing anything beyond the scaffold makes it discoverable
-- without requiring a save, and clearing the text hides it again.
local blank = yap.eval_session({ buf = src })
local blank_path = vim.b[blank].yap_path
assert(not is_listed(blank_path), "empty eval unexpectedly listed")
local last = vim.api.nvim_buf_line_count(blank) - 1
vim.api.nvim_buf_set_lines(blank, last, last + 1, false, { "What does this file do?" })
assert(is_listed(blank_path), "typed eval prompt missing before save")
session.save(blank)
vim.api.nvim_buf_set_lines(blank, last, last + 1, false, { "" })
session.save(blank)
assert(not is_listed(blank_path), "cleared eval prompt still listed")
-- Sending an eval is a completed conversation, even if it has no description.
vim.api.nvim_buf_set_lines(blank, last, last + 1, false, { "What does this file do?" })
yap.send(blank)
assert(vim.wait(10000, function()
  return not require("harness.state").running[blank]
end, 50), "eval turn did not finish")
assert(is_listed(blank_path), "completed eval session missing")
vim.api.nvim_buf_delete(blank, { force = true })
assert(is_listed(blank_path), "completed eval hidden after unloading")

local wins_before = #vim.api.nvim_tabpage_list_wins(0)
local sbuf = yap.eval_session({ buf = src, line1 = 2, line2 = 2 })
assert(#vim.api.nvim_tabpage_list_wins(0) == wins_before + 1, "eval session did not open a split")
assert(vim.api.nvim_get_current_buf() == sbuf, "focus did not move to the eval session")
assert(vim.wo.winbar == "%!v:lua.require'harness'.winbar()", "eval split has no yap winbar")
local src_win = vim.fn.win_findbuf(src)[1]
assert(src_win, "source buffer not shown in any window")
assert(vim.wo[src_win].winbar == "", "eval session leaked the yap winbar onto the source window")
assert(vim.b[sbuf].yap_provider == "mock" and vim.b[sbuf].yap_model == "m1", "eval session did not use agent")
assert(vim.b[sbuf].yap, "eval split is not a yap session")
-- The eval session is created hidden (no window for fold.setup_buffer to
-- project), then shown in the split: its default view 2 must still fold the
-- system prompt.
local sys_line = nil
for i, l in ipairs(vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)) do
  if l:match("^# @system%s*$") then
    sys_line = i
    break
  end
end
assert(sys_line, "eval session has no # @system heading")
assert(fold.level() == 2, "eval session default view is not 2")
assert(vim.fn.foldclosed(sys_line) == sys_line, "eval session system prompt is not folded at view 2")
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
assert(is_listed(spath), "eval session missing from sessions()")
yap.config.model_groups.flash = ""
assert(select(2, eval.combo()) == "m1", "empty flash should use agent")

-- No tools were offered to the provider.
local log = io.open("/tmp/yap-eval.log", "r")
assert(log, "eval mock log missing")
local text = log:read("*a")
log:close()
local one_shot = 0
for line in text:gmatch("[^\n]+") do
  local okj, req = pcall(vim.json.decode, line)
  if okj and req.model == "flash" then
    one_shot = one_shot + 1
    assert(not (req.tools and type(req.tools) == "table" and #req.tools > 0), "eval offered tools: " .. line)
  end
end
assert(one_shot >= 4, "one-shot eval requests missing")

print("OK eval")
