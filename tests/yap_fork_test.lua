local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ model_groups = { agent = "mock/m1", flash = "" } })
vim.cmd("runtime plugin/yap.lua")
local paths = require("harness.path")
local frontmatter = require("harness.model.frontmatter")

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local original_buf = yap.new()
local original = vim.b[original_buf].yap_path
local original_audit = paths.audit_path(original_buf)
vim.fn.mkdir(vim.fn.fnamemodify(original_audit, ":h"), "p")
vim.fn.writefile({ '{"type":"turn_end","prompt":42,"completion":3}' }, original_audit)
vim.api.nvim_buf_set_lines(original_buf, -1, -1, false, { "fork-only unsaved change" })
assert(vim.bo[original_buf].modified, "source should be dirty")

-- A session with dropped photos carries its assets folder into the fork and
-- re-points the references at the copy.
local src_assets = paths.assets_dir(original_buf)
vim.fn.mkdir(src_assets, "p")
local image = "\137PNG\r\n\26\n" .. string.rep("x", 40)
local src_image = src_assets .. "/photo.png"
local ifd = assert(vim.uv.fs_open(src_image, "w", 384))
assert(vim.uv.fs_write(ifd, image, 0) == #image)
vim.uv.fs_close(ifd)
vim.api.nvim_buf_set_lines(
  original_buf,
  -1,
  -1,
  false,
  { "", "![FILE: photo.png](" .. vim.uri_from_fname(src_image) .. ")" }
)
-- A :YapClear placeholder names the audit log it points at. A fork must
-- re-point it at its own copy, or deleting the parent dangles it.
vim.api.nvim_buf_set_lines(
  original_buf,
  -1,
  -1,
  false,
  { "", "[output cleared — full output in the audit log: " .. vim.fn.fnamemodify(original_audit, ":~") .. ":1]" }
)

vim.cmd("YapFork forked")
local fork_buf = vim.api.nvim_get_current_buf()
local fork = vim.b[fork_buf].yap_path
local expected_dir = paths.session_dir(vim.b[original_buf].yap_project_cwd)
assert(
  fork_buf ~= original_buf and fork == expected_dir .. "/forked/session.md",
  "fork must open an independent buffer"
)
assert(
  vim.b[original_buf].yap_path == original and vim.api.nvim_buf_get_name(original_buf) == original,
  "source renamed"
)
assert(text(original_buf):match("fork%-only unsaved change"), "source changed")
assert(vim.fn.filereadable(fork) == 1 and not vim.bo[fork_buf].modified, "fork should be a clean file-backed buffer")
assert(text(fork_buf):match("fork%-only unsaved change"), "unsaved source text was not copied")
assert(not text(original_buf):find("session_forked", 1, true), "fork marker leaked into the source")
assert(not vim.b[fork_buf].yap_resume_pending, "a fresh fork was marked as resumed")
local fork_marker = assert(text(fork_buf):match("<!%-%- yap:event (.-) %-%->"), "fork marker missing")
local fork_event = vim.json.decode(fork_marker)
assert(fork_event.type == "session_forked" and fork_event.source == vim.uri_from_fname(original))
assert(
  table.concat(vim.fn.readfile(original), "\n"):match("fork%-only unsaved change"),
  "source was not saved with fork links"
)
assert(
  frontmatter.parse(vim.fn.readfile(fork)).forked_from == vim.fn.fnamemodify(original, ":h"),
  "fork parent link missing"
)
local fork_image = paths.assets_dir(fork_buf) .. "/photo.png"
assert(vim.fn.filereadable(fork_image) == 1, "fork did not copy the session assets")
assert(
  table.concat(vim.fn.readfile(fork_image), "\n") == table.concat(vim.fn.readfile(src_image), "\n"),
  "fork asset copy differs from the source"
)
assert(
  text(fork_buf):find(vim.uri_from_fname(fork_image), 1, true),
  "fork asset reference was not re-pointed at the copy"
)
assert(not text(fork_buf):find(vim.uri_from_fname(src_image), 1, true), "fork still points at the source asset")
local fork_audit_ref = vim.fn.fnamemodify(paths.audit_path(fork_buf), ":~")
assert(
  text(fork_buf):find(fork_audit_ref, 1, true) and not text(fork_buf):find(vim.fn.fnamemodify(original_audit, ":~"), 1, true),
  "fork did not re-point cleared placeholder at its own audit log"
)
local saved_items = require("harness.session").list()
local source_index, fork_index
for i, item in ipairs(saved_items) do
  if item.path == original then
    source_index = i
  elseif item.path == fork then
    fork_index = i
  end
end
assert(source_index and fork_index == source_index + 1, "saved fork not beneath source: " .. vim.inspect(saved_items))
assert(saved_items[fork_index].text == "forked", "saved fork label wrong")
assert(saved_items[fork_index].rail == "└─ ", "saved fork rail wrong: " .. vim.inspect(saved_items[fork_index]))
assert(saved_items[fork_index].icon == yap.config.icons.fork, "saved fork icon wrong")
local select = vim.ui.select
vim.api.nvim_set_current_buf(fork_buf)
assert(vim.b[fork_buf].yap and vim.b[fork_buf].yap_model == vim.b[original_buf].yap_model, "fork not adopted")
assert(vim.wo.winbar == "%!v:lua.require'harness'.winbar()", "fork window has no yap winbar")
assert(frontmatter.parse(vim.fn.readfile(fork)).created_at, "fork frontmatter missing")

local fork_audit = paths.audit_path(fork_buf)
assert(fork_audit ~= original_audit and vim.fn.filereadable(fork_audit) == 1, "audit not copied independently")
local fork_audit_lines = vim.fn.readfile(fork_audit)
assert(fork_audit_lines[1] == vim.fn.readfile(original_audit)[1], "audit history differs")
assert(
  #fork_audit_lines == 2 and vim.json.decode(fork_audit_lines[2]).type == "session_forked",
  "fork audit missing fork marker: " .. vim.inspect(fork_audit_lines)
)
-- The fork inherits the journal, but its all-time accounting restarts at the
-- fork marker: the inherited turn is history, not this branch's spend.
local fork_usage = vim.b[fork_buf].yap_session_usage
assert(
  fork_usage and (fork_usage.prompt or 0) == 0 and (fork_usage.cost or 0) == 0,
  "fork inherited parent usage: " .. vim.inspect(fork_usage)
)
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
  generated:match("^" .. vim.pesc(expected_dir) .. "/%d%d%-%d%d/%d%d%-%d+/session%.md$"),
  "unexpected generated fork name: " .. generated
)
assert(frontmatter.parse(vim.fn.readfile(generated)).forked_from == vim.fn.fnamemodify(fork, ":h"), "nested fork parent missing")
local nested_items = require("harness.session").list()
local nested_parent, nested_child
for i, item in ipairs(nested_items) do
  if item.path == fork then
    nested_parent = i
  elseif item.path == generated then
    nested_child = i
  end
end
assert(nested_parent and nested_child == nested_parent + 1, "nested saved fork not beneath parent")
assert(nested_items[nested_child].rail == "   └─ ", "nested fork indentation wrong: " .. vim.inspect(nested_items[nested_child]))
assert(nested_items[nested_child].icon == yap.config.icons.fork, "nested fork icon wrong")
assert(vim.wo.winbar == "%!v:lua.require'harness'.winbar()", "nested fork window has no yap winbar")
local nested_buf = vim.api.nvim_get_current_buf()
local saved_capture
vim.ui.select = function(items)
  saved_capture = items
end
yap.sessions()
vim.ui.select = select
local saved_positions = {}
for i, item in ipairs(saved_capture or {}) do
  saved_positions[item.path] = i
end
assert(
  saved_positions[original]
    and saved_positions[fork] == saved_positions[original] + 1
    and saved_positions[generated] == saved_positions[fork] + 1,
  "saved fork tree is broken from within its leaf: " .. vim.inspect(saved_capture)
)
local visible = false
for _, item in ipairs(require("harness.session").list()) do
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
assert(
  frontmatter.parse(vim.fn.readfile(fork)).forked_from == vim.fn.fnamemodify(original, ":h"),
  "fork parent link lost after reopen"
)
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
local running_audit = vim.fn.readfile(paths.audit_path(running_buf))
assert(
  #running_audit == 2
    and vim.json.decode(running_audit[1]).type == "turn_end"
    and vim.json.decode(running_audit[2]).type == "session_forked",
  "in-flight audit leaked into fork: " .. vim.inspect(running_audit)
)
assert(
  vim.wait(10000, function()
    return not yap.is_running(active)
  end, 50),
  "original did not finish"
)
assert(
  frontmatter.parse(vim.fn.readfile(running_fork)).forked_from == vim.fn.fnamemodify(active_path, ":h"),
  "running fork parent link missing"
)
assert(text(active):find("active question", 1, true), "running source was altered")

local after_close = require("harness.session").list()
local positions = {}
for i, item in ipairs(after_close) do
  positions[item.path] = i
end
assert(
  positions[original] and positions[fork] == positions[original] + 1 and positions[generated] == positions[fork] + 1,
  "saved history lost fork nesting after :bd"
)
print("OK fork")
