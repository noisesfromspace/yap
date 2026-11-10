-- The session picker previews the saved file: the initial # @user message and
-- the last # @assistant answer, rendered as markdown. preview() is also the
-- shared preview used by the single sessions() picker.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local session = require("harness.session")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })

-- preview() returns a { buf = ... } table per the vim.ui.select() preview
-- contract; the buffer is markdown so pickers syntax-highlight the excerpts.
local function preview_text(result)
  assert(
    type(result) == "table" and result.buf and vim.api.nvim_buf_is_valid(result.buf),
    "preview must return a { buf = ... } table: " .. vim.inspect(result)
  )
  assert(vim.bo[result.buf].filetype == "markdown", "preview buffer must be markdown")
  return vim.api.nvim_buf_get_lines(result.buf, 0, -1, false)
end

-- preview extracts the first user block and the last assistant block,
-- headings excluded, surrounding blank lines trimmed, and renders them as
-- markdown sections separated by a horizontal rule.
local convo = {
  "# @system",
  "",
  "system",
  "",
  "# @user",
  "",
  "first question",
  "second line",
  "",
  "# @assistant",
  "",
  "first answer",
  "",
  "# @user",
  "",
  "second question",
  "",
  "# @assistant",
  "",
  "last answer line 1",
  "last answer line 2",
}
local lines = preview_text(session.preview(convo))
assert(lines[1] == "## First message", "unexpected preview: " .. vim.inspect(lines))
assert(lines[3] == "first question" and lines[4] == "second line", "first user message wrong: " .. vim.inspect(lines))
assert(lines[6] == "---" and lines[8] == "## Last answer", "separator / answer heading wrong: " .. vim.inspect(lines))
assert(
  lines[10] == "last answer line 1" and lines[11] == "last answer line 2",
  "last agent answer wrong: " .. vim.inspect(lines)
)
assert(preview_text(session.preview({}))[1] == "(no messages yet)", "empty preview missing")

-- The preview is the user-facing outcome, not the tool transcript or an
-- unfinished thinking-only reply. Literal markdown and ordinary comments stay.
local rich = vim.list_extend(vim.deepcopy(convo), {
  "",
  "<!-- yap:thinking",
  "unfinished reasoning",
  "-->",
  '<!-- yap:tool {"id":"x","name":"bash"} -->',
  "tool output",
  "# @user",
  "quoted inside tool",
  "<!-- /yap:tool -->",
  "<!-- yap:model m1 -->",
  "<!-- ordinary comment -->",
  "",
  "# @user",
  "",
  "new question",
  "",
  "# @assistant",
  "",
  "<!-- yap:thinking",
  "still working",
  "-->",
})
local rich_preview = table.concat(preview_text(session.preview(rich)), "\n")
assert(rich_preview:find("last answer line 2", 1, true), "lost last completed answer")
assert(rich_preview:find("ordinary comment", 1, true), "ordinary markdown comment lost")
for _, hidden in ipairs({ "unfinished reasoning", "tool output", "quoted inside tool", "still working", "yap:model" }) do
  assert(not rich_preview:find(hidden, 1, true), "display region leaked: " .. hidden)
end

-- Removed display blocks must not leave empty paragraphs in the answer.
-- Keep blank lines that genuinely separate answer paragraphs.
local spaced = preview_text(session.preview({
  "# @user",
  "",
  "question",
  "",
  "# @assistant",
  "",
  "<!-- yap:thinking",
  "reasoning",
  "-->",
  "",
  "First paragraph",
  "",
  '<!-- yap:tool {"id":"x","name":"bash"} -->',
  "result",
  "<!-- /yap:tool -->",
  "",
  "<!-- yap:model m1 -->",
  "",
  "Second paragraph",
  "",
  "Third paragraph",
  "",
  "<!-- yap:error failure -->",
  "",
  "Final line",
  "",
  "<!-- yap:thinking",
  "trailing reasoning",
  "-->",
  "",
}))
assert(
  vim.deep_equal(vim.list_slice(spaced, 9), {
    "First paragraph",
    "Second paragraph",
    "",
    "Third paragraph",
    "Final line",
  }),
  "display blocks left blank lines: " .. vim.inspect(spaced)
)

local captured
local orig_select = vim.ui.select

-- The single picker previews the saved file with the same excerpts.
local saved = yap.new()
vim.api.nvim_buf_set_lines(saved, 0, -1, false, {
  "---",
  "provider: mock",
  "model: m1",
  "description: Preview test",
  "---",
  "",
  "# @user",
  "",
  "history question",
  "",
  "# @assistant",
  "",
  "<!-- yap:thinking",
  "saved reasoning",
  "-->",
  "history answer",
  '<!-- yap:tool {"id":"x","name":"bash"} -->',
  "saved tool result",
  "<!-- /yap:tool -->",
})
session.save(saved)
local path = vim.b[saved].yap_path
assert(path and vim.fn.filereadable(path) == 1, "session not saved")
local saved_child = yap.new({ agent = "scout", system = "Scout agent", hidden = true })
local saved_child_path = vim.b[saved_child].yap_path
local child_lines = vim.api.nvim_buf_get_lines(saved_child, 0, -1, false)
child_lines[#child_lines + 1] =
  "Investigate a very long title that must stay searchable and never be artificially truncated"
vim.api.nvim_buf_set_lines(saved_child, 0, -1, false, child_lines)
session.save(saved_child)
require("harness.model.frontmatter").update(saved_child, { subagent_parent = vim.fn.fnamemodify(path, ":h") })
session.save(saved_child)

captured = nil
vim.ui.select = function(items, opts, on_choice)
  captured = { items = items, opts = opts, on_choice = on_choice }
end
session.pick({}, function(selected)
  assert(selected == path, "saved session selection failed")
end)
vim.ui.select = orig_select
assert(captured, "expected saved sessions")
local saved_index, saved_child_index
for i, item in ipairs(captured.items) do
  if item.path == path then
    saved_index = i
  elseif item.path == saved_child_path then
    saved_child_index = i
  end
end
assert(saved_index, "saved parent missing: " .. vim.inspect(captured.items))
assert(
  saved_child_index == saved_index + 1,
  "saved subagent not nested beneath its open parent: " .. vim.inspect(captured.items)
)
-- The row counts completed replies and the agent sessions the conversation
-- spawned, each with its own unit.
local saved_row = captured.opts.format_item(captured.items[saved_index])
assert(saved_row:find("(1 turn & 1 subagent)", 1, true), "counts label wrong: " .. saved_row)
captured.on_choice(captured.items[saved_index])
-- A subagent's identity is never cut off however long the task is.
local child_label = session.live_label(saved_child, true)
assert(
  child_label:find(
    "scout · Investigate a very long title that must stay searchable and never be artificially truncated",
    1,
    true
  ),
  "child title was cut off: " .. child_label
)
assert(type(captured.opts.preview_item) == "function", "saved preview_item missing")
local saved_preview = preview_text(captured.opts.preview_item(captured.items[saved_index]))
assert(
  saved_preview[1] == "## First message" and saved_preview[3] == "history question",
  "saved preview wrong: " .. vim.inspect(saved_preview)
)
assert(saved_preview[#saved_preview] == "history answer", "saved last answer wrong: " .. vim.inspect(saved_preview))
assert(not table.concat(saved_preview):find("saved reasoning", 1, true), "saved preview leaked thinking")

-- A description wins in session views; renamed children still prefer their
-- filename title over the task when they have no description yet.
local dir = require("harness.path").session_dir(vim.fn.getcwd())
local titled_parent = yap.new({ path = dir .. "/titled-history-parent/session.md" })
local titled_child = yap.new({ agent = "scout", hidden = true })
-- Rename each transcript to set its title (the filename is the title).
local function type_title(buf, value)
  local d = vim.fn.fnamemodify(vim.b[buf].yap_path, ":h")
  vim.api.nvim_buf_set_name(buf, d .. "/" .. value .. ".md")
end
vim.api.nvim_buf_set_lines(
  titled_child,
  -1,
  -1,
  false,
  { "original task", "", "# @assistant", "", "done", "", "# @user", "", "follow-up task" }
)
type_title(titled_child, "Pinned child title")
type_title(titled_parent, "Pinned parent title")
local titled_child_path = vim.api.nvim_buf_get_name(titled_child)
local titled_parent_path = vim.api.nvim_buf_get_name(titled_parent)
vim.api.nvim_buf_set_lines(titled_child, 3, 3, false, { "subagent_parent: " .. vim.fn.fnamemodify(titled_parent_path, ":h") })
session.save(titled_child)
session.save(titled_parent)
local titled_items = session.list()
local titled_positions = {}
for i, item in ipairs(titled_items) do
  titled_positions[item.path] = i
end
assert(titled_positions[titled_parent_path], "titled parent missing: " .. vim.inspect(titled_items))
assert(
  titled_positions[titled_child_path] == titled_positions[titled_parent_path] + 1,
  "titled subagent not nested beneath its open parent: " .. vim.inspect(titled_items)
)
assert(
  titled_items[titled_positions[titled_parent_path]].text == "Pinned parent title",
  "filename fallback missing without a description: " .. vim.inspect(titled_items)
)
assert(
  titled_items[titled_positions[titled_child_path]].text == "scout · Pinned child title",
  "child should prefer its filename title: " .. vim.inspect(titled_items[titled_positions[titled_child_path]])
)

-- The sessions picker annotates open sessions with their live status: a
-- pending approval wins over every other state, then running, stopped,
-- waiting, and idle.
local state = require("harness.state")
local icons = yap.config.icons
local function sessions_status(expected)
  captured = nil
  vim.ui.select = function(items, opts)
    captured = { items = items, opts = opts }
  end
  yap.sessions()
  vim.ui.select = orig_select
  local item
  for _, candidate in ipairs(captured and captured.items or {}) do
    if candidate.path == path then
      item = candidate
    end
  end
  assert(item, "expected saved sessions row: " .. vim.inspect(captured))
  local rendered = captured.opts.format_item(item)
  assert(rendered:find("^" .. expected .. "  ") == 1, "sessions icon is not in the fixed column: " .. rendered)
end
state.pending_approvals[saved] = {}
sessions_status(icons.approval)
state.pending_approvals[saved] = nil
state.running[saved] = {}
sessions_status(icons.running)
state.running[saved] = nil
state.awaiting[saved] = true
sessions_status(icons.waiting)
state.stopped[saved] = true
sessions_status(icons.stopped)
state.awaiting[saved], state.stopped[saved] = nil, nil
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.sessions()
vim.ui.select = orig_select
local idle_row
for _, item in ipairs(captured.items) do
  if item.path == path then
    idle_row = captured.opts.format_item(item)
  end
end
assert(
  idle_row and idle_row:find("^" .. icons.idle .. "  ") == 1,
  "open idle saved session needs a live icon: " .. tostring(idle_row)
)
-- A closed session still reserves the status column; its title starts in
-- the same place as an open session's title.
vim.api.nvim_buf_delete(saved, { force = true })
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.sessions()
vim.ui.select = orig_select
for _, item in ipairs(captured.items) do
  local row = captured.opts.format_item(item)
  if item.path == path then
    assert(row:find("^   Preview test") == 1, "closed session title shifted: " .. row)
  end
end
-- A closed parent hides its subagents, so the child is no longer a row.
for _, item in ipairs(captured.items) do
  assert(item.path ~= saved_child_path, "subagent shown under a closed parent: " .. item.path)
end
-- Closing the child leaves the closed parent's history unchanged.
vim.api.nvim_buf_delete(saved_child, { force = true })
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.sessions()
vim.ui.select = orig_select
for _, item in ipairs(captured.items) do
  local row = captured.opts.format_item(item)
  if item.path == path then
    assert(row:find("^   Preview test") == 1, "closed parent title moved: " .. row)
  elseif item.path == saved_child_path then
    error("closed agent session leaked into saved history: " .. row)
  end
end

-- The all-project picker lists every project under the sessions root and
-- places the project after each root title (not before the status column);
-- children keep their indented titles without repeating it.
local paths = require("harness.path")
local other_dir = paths.session_dir("/tmp/yap-other-project")
vim.fn.mkdir(other_dir .. "/other-project", "p")
vim.fn.writefile(vim.fn.readfile(path), other_dir .. "/other-project/session.md")
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.sessions("all")
vim.ui.select = orig_select
local all_parent, all_child, other_row
for _, item in ipairs(captured.items) do
  local row = captured.opts.format_item(item)
  if item.path == path then
    all_parent = row
  end
  if item.path == saved_child_path then
    all_child = row
  end
  if item.path == other_dir .. "/other-project/session.md" then
    other_row = row
  end
end
assert(
  all_parent and all_parent:find("^   Preview test") == 1 and all_parent:find(paths.project_cwd(path), 1, true),
  "sessions cwd should follow root title: " .. tostring(all_parent)
)
assert(all_child == nil, "agent session leaked into the all-project picker: " .. tostring(all_child))
assert(
  other_row and other_row:find("^   Preview test") == 1 and other_row:find("/tmp/yap/other/project", 1, true),
  "other project prefix missing: " .. tostring(other_row)
)

print("OK session_preview")
