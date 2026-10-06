local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ provider = "mock", model = "m1" })
vim.cmd("runtime plugin/yap.lua")
local paths = require("harness.path")
local frontmatter = require("harness.frontmatter")

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local original_buf = yap.new()
local original = vim.b[original_buf].yap_path
local original_audit = paths.audit_path(original_buf)
vim.fs.mkdir(vim.fn.fnamemodify(original_audit, ":h"), { parents = true })
vim.fn.writefile({ '{"type":"turn_end","prompt":42,"completion":3}' }, original_audit)
vim.api.nvim_buf_set_lines(original_buf, -1, -1, false, { "fork-only unsaved change" })
assert(vim.bo[original_buf].modified, "source should be dirty")

vim.cmd("YapFork forked")
local fork_buf = vim.api.nvim_get_current_buf()
local fork = vim.b[fork_buf].yap_path
local expected_dir = paths.session_dir(vim.b[original_buf].yap_project_cwd)
assert(fork_buf ~= original_buf and fork == expected_dir .. "/forked.md", "fork must open an independent buffer")
assert(
  vim.b[original_buf].yap_path == original and vim.api.nvim_buf_get_name(original_buf) == original,
  "source renamed"
)
assert(text(original_buf):match("fork%-only unsaved change"), "source changed")
assert(vim.fn.filereadable(fork) == 1 and not vim.bo[fork_buf].modified, "fork should be a clean file-backed buffer")
assert(text(fork_buf):match("fork%-only unsaved change"), "unsaved source text was not copied")
assert(
  table.concat(vim.fn.readfile(original), "\n"):match("fork%-only unsaved change"),
  "source was not saved with fork links"
)
assert(vim.deep_equal(frontmatter.parse(vim.fn.readfile(original)).forks, { fork }), "source fork link missing")
assert(frontmatter.parse(vim.fn.readfile(fork)).forked_from == original, "fork parent link missing")
local saved_items = require("harness.session").list("cwd")
local source_index, fork_index
for i, item in ipairs(saved_items) do
  if item.path == original then
    source_index = i
  elseif item.path == fork then
    fork_index = i
  end
end
assert(source_index and fork_index == source_index + 1, "saved fork not beneath source: " .. vim.inspect(saved_items))
assert(saved_items[fork_index].text == "  ↳ fork · forked.md", "saved fork label wrong")
local captured
local select = vim.ui.select
vim.ui.select = function(items)
  captured = items
end
vim.api.nvim_set_current_buf(original_buf)
yap.instances()
vim.ui.select = select
local live_source, live_fork
for i, item in ipairs(captured) do
  if item.buf == original_buf then
    live_source = i
  elseif item.buf == fork_buf then
    live_fork = i
  end
end
assert(live_source and live_fork == live_source + 1, "open fork not beneath source: " .. vim.inspect(captured))
assert(captured[live_fork].text == "↳ fork · forked.md", "open fork label wrong")
vim.api.nvim_set_current_buf(fork_buf)
assert(vim.b[fork_buf].yap and vim.b[fork_buf].yap_model == vim.b[original_buf].yap_model, "fork not adopted")
assert(vim.wo.winbar == "%!v:lua.require'harness'.winbar()", "fork window has no yap winbar")
assert(frontmatter.parse(vim.fn.readfile(fork)).created_at, "fork frontmatter missing")

local fork_audit = paths.audit_path(fork_buf)
assert(fork_audit ~= original_audit and vim.fn.filereadable(fork_audit) == 1, "audit not copied independently")
assert(vim.fn.readfile(fork_audit)[1] == vim.fn.readfile(original_audit)[1], "audit history differs")
vim.fn.writefile({ '{"type":"turn_end","prompt":1,"completion":1}' }, fork_audit, "a")
assert(#vim.fn.readfile(original_audit) == 1, "fork wrote into source audit")

vim.api.nvim_buf_set_lines(fork_buf, -1, -1, false, { "fork's next prompt" })
require("harness.session").save(fork_buf)
assert(not text(original_buf):match("fork's next prompt"), "fork edits leaked into source buffer")
assert(
  table.concat(vim.fn.readfile(original), "\n"):match("fork%-only unsaved change"),
  "fork save changed source file"
)
assert(not yap.fork("forked"), "existing fork overwritten")
assert(vim.api.nvim_get_current_buf() == fork_buf, "failed fork changed focus")
assert(not require("harness.session").fork(fork_buf, "../outside"), "path escape accepted")
local generated = assert(yap.fork())
assert(
  generated:match("^" .. vim.pesc(expected_dir) .. "/%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%x%x%x%x%.md$"),
  "unexpected generated fork name: " .. generated
)
assert(frontmatter.parse(vim.fn.readfile(generated)).forked_from == fork, "nested fork parent missing")
local nested_items = require("harness.session").list("cwd")
local nested_parent, nested_child
for i, item in ipairs(nested_items) do
  if item.path == fork then
    nested_parent = i
  elseif item.path == generated then
    nested_child = i
  end
end
assert(nested_parent and nested_child == nested_parent + 1, "nested saved fork not beneath parent")
assert(nested_items[nested_child].text:find("    ↳ fork · ", 1, true) == 1, "nested fork indentation wrong")
assert(vim.wo.winbar == "%!v:lua.require'harness'.winbar()", "nested fork window has no yap winbar")
local visible = false
for _, item in ipairs(require("harness.session").list("cwd")) do
  if item.path == generated then
    visible = true
  end
end
assert(visible, "unnamed fork hidden from history")
assert(vim.api.nvim_get_current_buf() ~= fork_buf, "generated fork reused the source buffer")

-- Opening the old path must focus its existing buffer rather
-- than confusing it with the fork.
yap.open(original)
assert(vim.api.nvim_get_current_buf() == original_buf, "source cannot be resumed")
assert(frontmatter.parse(vim.fn.readfile(original)).forks[1] == fork, "fork reference lost after reopen")
assert(not text(original_buf):match("fork's next prompt"), "source displays fork state")
-- A running fork excludes the user request being answered and the partial
-- assistant response, retaining only the last completed turn and its audit.
local active = yap.new()
local active_path = vim.b[active].yap_path
vim.api.nvim_buf_set_lines(active, -1, -1, false, {
  "completed question",
  "",
  "# @assistant",
  "",
  "completed answer",
  "",
  "# @user",
  "",
  "active question",
})
require("harness.session").save(active)
local active_audit = paths.audit_path(active)
vim.fn.writefile(
  { '{"type":"turn_end","prompt":10,"completion":2}', '{"type":"tool_call","id":"in-flight"}' },
  active_audit
)
yap.send(active)
assert(
  vim.wait(5000, function()
    return text(active):find("The slow", 1, true) ~= nil
  end, 20),
  "mock did not start streaming"
)
local running_fork = assert(yap.fork("while-running"))
local running_buf = vim.api.nvim_get_current_buf()
local running_text = text(running_buf)
assert(
  running_text:find("completed answer", 1, true) and not running_text:find("active question", 1, true),
  "running turn leaked into fork"
)
assert(not running_text:find("The slow", 1, true), "partial reply leaked into fork")
assert(running_text:match("# @user%s*$"), "fork lacks a fresh prompt")
assert(frontmatter.parse(vim.fn.readfile(running_fork)).turns == 1, "fork turn count wrong")
assert(#vim.fn.readfile(paths.audit_path(running_buf)) == 1, "in-flight audit leaked into fork")
assert(
  vim.wait(10000, function()
    return not yap.is_running(active)
  end, 50),
  "original did not finish"
)
assert(
  frontmatter.parse(vim.fn.readfile(active_path)).forks[1] == running_fork,
  "running source fork link not persisted"
)
assert(text(active):find("active question", 1, true), "running source was altered")
print("OK fork")
