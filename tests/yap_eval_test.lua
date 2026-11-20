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

-- One-shot evals leave ordinary, reopenable transcripts, but do not appear
-- in either saved-session scope or in the live winbar rollup.
local eval_paths = vim.fn.glob(require("harness.path").session_dir(vim.fn.getcwd()) .. "/**/eval-*.md", false, true)
assert(#eval_paths == 4, "one-shot eval files missing: " .. vim.inspect(eval_paths))
local saved_sessions = require("harness.session")
for _, path in ipairs(eval_paths) do
  local recorded = table.concat(vim.fn.readfile(path), "\n")
  assert(recorded:find("kind: eval", 1, true), "eval kind missing: " .. path)
  assert(recorded:find("eval_status: applied", 1, true), "eval outcome missing: " .. path)
  assert(recorded:find("summarized output", 1, true), "eval answer missing: " .. path)
  assert(recorded:find("# @user", 1, true), "eval request missing: " .. path)
  assert(not vim.tbl_contains(vim.tbl_map(function(item) return item.path end, saved_sessions.list()), path), "eval listed")
  assert(not vim.tbl_contains(vim.tbl_map(function(item) return item.path end, saved_sessions.list("all")), path), "eval listed globally")
end
local reopened = vim.fn.bufadd(eval_paths[1])
vim.fn.bufload(reopened)
require("harness.session.buffers").adopt(reopened, eval_paths[1])
assert(vim.b[reopened].yap, "eval record cannot reopen as session")
require("harness.state").awaiting[reopened] = true
assert(yap.overview(plain) == "", "eval record leaked into overview")
assert(not vim.tbl_contains(vim.tbl_map(function(item) return item.path end, saved_sessions.list()), eval_paths[1]), "loaded eval listed")
vim.api.nvim_buf_delete(reopened, { force = true })
local changed = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(changed, 0, -1, false, { "new text" })
assert(eval.finish(changed, 1, 1, { "old text" }, { code = 0, stdout = "answer" }) == "source_changed")
assert(vim.api.nvim_buf_get_lines(changed, 0, -1, false)[1] == "new text", "stale eval overwrote source")
vim.api.nvim_buf_delete(changed, { force = true })

-- :YapEval (no bang) sends from a hidden, saved session and never edits
-- the source or opens a window. The no-instruction form prompts first.
local src = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(src)
vim.bo[src].filetype = "go"
vim.api.nvim_buf_set_lines(src, 0, -1, false, { "a", "x := `y`", "c" })
vim.api.nvim_buf_set_name(src, vim.fn.tempname() .. ".go")
local session = require("harness.session")
local before = vim.api.nvim_get_current_win()
local wins_before = #vim.api.nvim_tabpage_list_wins(0)
local sbuf = yap.eval_session({ buf = src, line1 = 2, line2 = 2, instruction = "Explain this" })
assert(vim.api.nvim_get_current_win() == before and vim.api.nvim_get_current_buf() == src, "eval moved focus")
assert(#vim.api.nvim_tabpage_list_wins(0) == wins_before, "eval opened a window")
assert(vim.b[sbuf].yap_provider == "mock" and vim.b[sbuf].yap_model == "m1", "eval did not use agent")
assert(vim.b[sbuf].yap_kind == "eval", "eval kind missing from buffer")
assert(vim.wait(10000, function() return not require("harness.state").running[sbuf] end, 50), "eval did not finish")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(src, 0, -1, false), { "a", "x := `y`", "c" }), "eval changed source")
local spath = vim.b[sbuf].yap_path
assert(spath and vim.fn.filereadable(spath) == 1, "eval session not saved")
local stext = table.concat(vim.fn.readfile(spath), "\n")
assert(stext:find("kind: eval", 1, true), "eval kind not saved")
assert(stext:find("```go\nx := `y`\n```", 1, true), "selection not quoted: " .. stext)
assert(stext:find("summarized output", 1, true), "eval answer not saved: " .. stext)
assert(not stext:find("return ONLY the result", 1, true), "eval used one-shot system prompt")
assert(not vim.tbl_contains(vim.tbl_map(function(item) return item.path end, session.list()), spath), "eval listed")
assert(not vim.tbl_contains(vim.tbl_map(function(item) return item.path end, session.list("all")), spath), "eval listed globally")
assert(yap.overview(src) == "", "eval leaked into overview")
vim.api.nvim_buf_delete(sbuf, { force = true })
assert(vim.fn.filereadable(spath) == 1, "closing eval lost its session")
local prompted
local original_input = vim.ui.input
vim.ui.input = function(_, callback) prompted = callback end
assert(yap.eval_session({ buf = src }) == nil, "no-instruction eval created a session")
vim.ui.input = original_input
assert(prompted, "eval did not prompt for an instruction")
prompted("Explain the file")
assert(vim.wait(10000, function()
  for _, path in ipairs(vim.fn.glob(require("harness.path").session_dir(vim.fn.getcwd()) .. "/**/session.md", false, true)) do
    if path ~= spath and table.concat(vim.fn.readfile(path), "\n"):find("Explain the file", 1, true) then
      return true
    end
  end
end, 50), "prompted eval did not create a session")
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
