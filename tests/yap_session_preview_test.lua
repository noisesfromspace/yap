-- Session picker previews: open-session picker and sessions()
-- (saved files) preview the same two excerpts — the initial # @user
-- message and the last # @assistant answer — instead of the raw item.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local session = require("harness.session")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

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
  "", "<!-- yap:thinking", "unfinished reasoning", "-->",
  "<!-- yap:tool {\"id\":\"x\",\"name\":\"bash\"} -->",
  "tool output", "# @user", "quoted inside tool", "<!-- /yap:tool -->",
  "<!-- yap:model m1 -->", "<!-- ordinary comment -->",
  "", "# @user", "", "new question", "", "# @assistant", "",
  "<!-- yap:thinking", "still working", "-->",
})
local rich_preview = table.concat(preview_text(session.preview(rich)), "\n")
assert(rich_preview:find("last answer line 2", 1, true), "lost last completed answer")
assert(rich_preview:find("ordinary comment", 1, true), "ordinary markdown comment lost")
for _, hidden in ipairs({ "unfinished reasoning", "tool output", "quoted inside tool", "still working", "yap:model" }) do
  assert(not rich_preview:find(hidden, 1, true), "display region leaked: " .. hidden)
end

-- The open-session picker previews another live buffer with the same excerpts.
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user", "", "hello", "", "# @assistant", "",
  "<!-- yap:thinking", "secret reasoning", "-->", "bye",
  "<!-- yap:tool {\"id\":\"x\",\"name\":\"bash\"} -->", "tool output", "<!-- /yap:tool -->",
})
yap.new() -- current session is included in the general picker
local captured
local orig_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
  captured = { items = items, opts = opts, on_choice = on_choice }
end
yap.instances()
vim.ui.select = orig_select
local other_item, current_item
for _, item in ipairs(captured and captured.items or {}) do
  if item.buf == buf then
    other_item = item
  elseif item.buf == vim.api.nvim_get_current_buf() then
    current_item = item
  end
end
assert(
  captured and #captured.items == 2 and other_item and current_item,
  "open picker should include the current session: " .. vim.inspect(captured and captured.items)
)
assert(type(captured.opts.preview_item) == "function", "instances preview_item missing")
local live_preview = preview_text(captured.opts.preview_item(other_item))
assert(
  live_preview[1] == "## First message" and live_preview[3] == "hello",
  "instances preview wrong: " .. vim.inspect(live_preview)
)
assert(live_preview[#live_preview] == "bye", "instances last answer wrong: " .. vim.inspect(live_preview))
assert(not table.concat(live_preview):find("secret reasoning", 1, true), "instances leaked thinking")

-- Removed display blocks must not leave empty paragraphs in the answer.
-- Keep blank lines that genuinely separate answer paragraphs.
local spaced = preview_text(session.preview({
  "# @user", "", "question", "", "# @assistant", "",
  "<!-- yap:thinking", "reasoning", "-->", "", "First paragraph", "",
  "<!-- yap:tool {\"id\":\"x\",\"name\":\"bash\"} -->", "result", "<!-- /yap:tool -->", "",
  "<!-- yap:model m1 -->", "", "Second paragraph", "", "Third paragraph",
  "", "<!-- yap:error failure -->", "", "Final line", "",
  "<!-- yap:thinking", "trailing reasoning", "-->", "",
}))
assert(vim.deep_equal(vim.list_slice(spaced, 9), {
  "First paragraph", "Second paragraph", "", "Third paragraph", "Final line",
}), "display blocks left blank lines: " .. vim.inspect(spaced))

-- A session can be wiped after the picker opens but before a queued preview
-- or choose callback runs (for example, after close_session completes).
local closed = yap.new()
vim.ui.select = function(items, opts, on_choice)
  captured = { items = items, opts = opts, on_choice = on_choice }
end
yap.instances()
vim.ui.select = orig_select
local closed_item
for _, item in ipairs(captured.items) do
  if item.buf == closed then
    closed_item = item
    break
  end
end
assert(closed_item, "closed session missing from picker")
vim.api.nvim_buf_delete(closed, { force = true })
assert(captured.opts.preview_item(closed_item) == nil, "closed session should not be previewed")
captured.on_choice(closed_item) -- must not try to focus an invalid buffer
captured.on_choice(other_item)
assert(vim.api.nvim_get_current_buf() == buf, "live picker choice should still focus its session")

-- Open child sessions are a separate picker row, indented beneath their parent.
local child = yap.new({ agent = "scout", hidden = true })
vim.b[child].yap_subagent_parent = buf
vim.b[child].yap_subagent_task = "inspect this task"
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
vim.api.nvim_set_current_buf(buf)
yap.instances()
vim.ui.select = orig_select
local parent_item, child_item
for _, item in ipairs(captured.items) do
  if item.buf == buf then
    parent_item = item
  end
  if item.buf == child then
    child_item = item
  end
end
assert(
  parent_item and not parent_item.text:find("\n", 1, true),
  "current parent with an open subagent should have its own picker row: " .. vim.inspect(parent_item)
)
assert(
  child_item and child_item.text == "↳ scout · inspect this task",
  "subagent should have a compact label: " .. vim.inspect(child_item)
)
local parent_position, child_position
for i, item in ipairs(captured.items) do
  if item.buf == buf then
    parent_position = i
  end
  if item.buf == child then
    child_position = i
  end
end
assert(
  parent_position and child_position == parent_position + 1,
  "child should stay directly below its parent: " .. vim.inspect(captured.items)
)
local rendered_child = captured.opts.format_item(child_item)
assert(
  rendered_child:find("^" .. yap.config.icons.idle .. "    ↳ scout · inspect this task") == 1
    and not rendered_child:find(vim.fn.getcwd(), 1, true)
    and not rendered_child:find("(m1)", 1, true),
  "child title should be indented after aligned status icon, without cwd/model: " .. rendered_child
)
local state = require("harness.state")
state.running[child] = {}
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.instances()
vim.ui.select = orig_select
parent_position, child_position = nil, nil
for i, item in ipairs(captured.items) do
  if item.buf == buf then
    parent_position = i
  end
  if item.buf == child then
    child_position = i
  end
end
assert(
  parent_position and child_position == parent_position + 1,
  "running child should remain grouped with waiting parent: " .. vim.inspect(captured.items)
)
assert(captured.opts.format_item(captured.items[child_position]):find("^" .. yap.config.icons.running .. "    ↳") == 1,
  "running child title should be indented after aligned icon")
state.running[child] = nil

-- Completed children do not need attention; stopped or errored ones do.
state.awaiting[buf] = true
state.awaiting[child] = true
local picker = yap.new()
vim.api.nvim_set_current_buf(picker)
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.waiting()
vim.ui.select = orig_select
assert(
  captured and #captured.items == 1 and captured.items[1].buf == buf,
  "waiting picker should show the parent but not its completed subagent: " .. vim.inspect(captured and captured.items)
)
-- The general picker still lists the completed subagent, but as "done"
-- rather than "waiting": its answer already went back to the parent.
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.instances()
vim.ui.select = orig_select
local done_child
for _, item in ipairs(captured.items) do
  if item.buf == child then
    done_child = item
  end
end
assert(done_child and done_child.state == "done", "completed subagent should be 'done': " .. vim.inspect(done_child))
assert(captured.opts.format_item(done_child):find("^" .. yap.config.icons.done .. "    ↳") == 1,
  "completed subagent should use the done icon: " .. captured.opts.format_item(done_child))
state.stopped[child] = true
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.waiting()
vim.ui.select = orig_select
assert(
  captured and #captured.items == 2 and captured.items[1].buf == buf and captured.items[2].buf == child,
  "stopped child needs attention beneath its parent: " .. vim.inspect(captured and captured.items)
)
assert(captured.opts.format_item(captured.items[1]):find("^" .. yap.config.icons.waiting .. " ") == 1,
  "waiting parent's icon should start the row")
assert(captured.opts.format_item(captured.items[2]):find("^" .. yap.config.icons.stopped .. "    ↳") == 1,
  "stopped child's title should be indented in waiting picker")
state.stopped[child] = nil
state.awaiting[buf], state.awaiting[child] = nil, nil

-- A manually stopped session is also part of the "needs you" set: <leader>w
-- lists it alongside waiting sessions.
state.stopped[buf] = true
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.waiting()
vim.ui.select = orig_select
assert(
  captured and #captured.items == 1 and captured.items[1].buf == buf,
  "waiting picker should list a stopped session: " .. vim.inspect(captured and captured.items)
)
assert(captured.items[1].state == "stopped", "stopped state missing: " .. vim.inspect(captured.items[1]))
state.stopped[buf] = nil

-- Across projects, keep the cwd after root titles rather than before icons.
local other_project = "/tmp/yap-other-project"
vim.b[picker].yap_project_cwd = other_project
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.instances()
vim.ui.select = orig_select
local root_row, child_row
for _, item in ipairs(captured.items) do
  if item.buf == buf then root_row = captured.opts.format_item(item) end
  if item.buf == child then child_row = captured.opts.format_item(item) end
end
assert(root_row and root_row:find("^" .. yap.config.icons.idle .. " ") == 1
  and root_row:find(" (" .. vim.fn.getcwd() .. ")", 1, true)
  and not root_row:find("(m1)", 1, true), "project path should replace model in parentheses: " .. tostring(root_row))
assert(child_row and child_row:find("^" .. yap.config.icons.idle .. "    ↳") == 1
  and not child_row:find(vim.fn.getcwd(), 1, true), "project path displaced child title: " .. tostring(child_row))
-- The waiting picker uses the same mixed-project labels, with no model.
state.awaiting[buf] = true
state.awaiting[picker] = true
vim.cmd("enew") -- neither project is current, so both waiting roots are listed
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.waiting()
vim.ui.select = orig_select
local waiting_root, waiting_other
for _, item in ipairs(captured.items) do
  if item.buf == buf then waiting_root = captured.opts.format_item(item) end
  if item.buf == picker then waiting_other = captured.opts.format_item(item) end
end
assert(waiting_root and waiting_root:find(" (" .. vim.fn.getcwd() .. ")", 1, true)
  and not waiting_root:find("(m1)", 1, true), "waiting row should show cwd instead of model: " .. tostring(waiting_root))
assert(waiting_other and waiting_other:find(" (" .. other_project .. ")", 1, true)
  and not waiting_other:find("(m1)", 1, true), "other project's waiting row should show its cwd: " .. tostring(waiting_other))
state.awaiting[buf], state.awaiting[picker] = nil, nil
vim.b[picker].yap_project_cwd = vim.fn.getcwd()

-- sessions() previews the saved file with the same excerpts.
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
  "<!-- yap:tool {\"id\":\"x\",\"name\":\"bash\"} -->",
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
vim.api.nvim_buf_set_lines(saved, 4, 4, false, { "subagents:", "  - " .. saved_child_path })
session.save(saved)

captured = nil
vim.ui.select = function(items, opts, on_choice)
  captured = { items = items, opts = opts, on_choice = on_choice }
end
session.pick({ scope = "cwd" }, function(selected)
  assert(selected == saved_child_path, "saved child selection failed")
end)
vim.ui.select = orig_select
assert(captured, "expected saved sessions")
local saved_index, saved_child_index
for i, item in ipairs(captured.items) do
  if item.path == path then
    saved_index = i
  end
  if item.path == saved_child_path then
    saved_child_index = i
  end
end
assert(
  saved_index and saved_child_index == saved_index + 1,
  "saved child should be selectable directly beneath its parent: " .. vim.inspect(captured.items)
)
captured.on_choice(captured.items[saved_child_index])
local child_label = captured.opts.format_item(captured.items[saved_child_index])
assert(
  child_label:find(
    "↳ scout · Investigate a very long title that must stay searchable and never be artificially truncated",
    1,
    true
  ),
  "saved child title was cut off: " .. child_label
)
assert(type(captured.opts.preview_item) == "function", "saved preview_item missing")
local saved_preview = preview_text(captured.opts.preview_item(captured.items[saved_index]))
assert(
  saved_preview[1] == "## First message" and saved_preview[3] == "history question",
  "saved preview wrong: " .. vim.inspect(saved_preview)
)
assert(saved_preview[#saved_preview] == "history answer", "saved last answer wrong: " .. vim.inspect(saved_preview))
assert(not table.concat(saved_preview):find("saved reasoning", 1, true), "saved preview leaked thinking")

-- A frontmatter title wins over the generated description for saved and
-- open sessions; a child still prefers its own title over the task when one
-- is present.
local dir = require("harness.path").session_dir(vim.fn.getcwd())
local titled_parent = yap.new({ path = dir .. "/titled-history-parent/session.md" })
local titled_parent_path = vim.b[titled_parent].yap_path
local titled_child = yap.new({ agent = "scout", hidden = true })
local titled_child_path = vim.b[titled_child].yap_path
-- Type the title into the always-present `title:` line, then add the child's
-- description and parent link into its frontmatter.
local function type_title(buf, value)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:match("^title:") then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { "title: " .. value })
      return
    end
  end
  error("no title line to edit")
end
vim.api.nvim_buf_set_lines(titled_child, -1, -1, false, { "original task", "", "# @assistant", "", "done", "", "# @user", "", "follow-up task" })
type_title(titled_child, "Pinned child title")
vim.api.nvim_buf_set_lines(titled_child, 3, 3, false, { "description: Generated follow-up description", "subagent_parent: " .. titled_parent_path })
session.save(titled_child)
type_title(titled_parent, "Pinned parent title")
vim.api.nvim_buf_set_lines(titled_parent, 3, 3, false, { "subagents:", "  - " .. titled_child_path })
session.save(titled_parent)
local titled_items = session.list("cwd")
local titled_positions = {}
for i, item in ipairs(titled_items) do
  titled_positions[item.path] = i
end
assert(titled_positions[titled_parent_path] and titled_positions[titled_child_path] == titled_positions[titled_parent_path] + 1,
  "titled parent lost its child: " .. vim.inspect(titled_items))
assert(titled_items[titled_positions[titled_parent_path]].text == "Pinned parent title",
  "title should win over description: " .. vim.inspect(titled_items))
assert(titled_items[titled_positions[titled_child_path]].text == "  ↳ scout · Pinned child title",
  "saved child should prefer its title over description/task: " .. vim.inspect(titled_items))
vim.api.nvim_set_current_buf(titled_parent)
local live_titled
vim.ui.select = function(items, opts)
  live_titled = { items = items, format = opts.format_item }
end
yap.instances()
vim.ui.select = orig_select
for _, item in ipairs(live_titled.items) do
  if item.buf == titled_child then
    assert(item.text == "↳ scout · Pinned child title", "open child should prefer its title: " .. item.text)
    assert(not live_titled.format(item):find("(m1)", 1, true), "open subagent row repeats its model")
  end
end

-- The sessions picker annotates saved sessions that are open with their live
-- state, including a manually stopped turn.
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
  if item.path == path then idle_row = captured.opts.format_item(item) end
end
assert(idle_row and idle_row:find("^" .. icons.idle .. "  ") == 1,
  "open idle saved session needs a live icon: " .. tostring(idle_row))
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
  elseif item.path == saved_child_path then
    assert(row:find("^" .. icons.idle .. "    ↳") == 1, "sessions child title should be indented after status: " .. row)
  end
end
-- Closing the child must not move either title or the arrow. The saved
-- picker keeps its status column even when neither of these rows is open.
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
    assert(row:find("^     ↳ scout") == 1, "closed child arrow moved: " .. row)
  end
end

-- The all-project sessions picker places the project after each root, not before the
-- status column; children keep their indented titles without repeating it.
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
  if item.path == path then all_parent = row end
  if item.path == saved_child_path then all_child = row end
  if item.path == other_dir .. "/other-project/session.md" then other_row = row end
end
assert(all_parent and all_parent:find("^   Preview test") == 1
  and all_parent:find(paths.project_cwd(path), 1, true), "sessions cwd should follow root title: " .. tostring(all_parent))
assert(all_child and all_child:find("^     ↳") == 1
  and not all_child:find(vim.fn.getcwd(), 1, true), "sessions child should not repeat project: " .. tostring(all_child))
assert(other_row and other_row:find("^   Preview test") == 1
  and other_row:find("/tmp/yap/other/project", 1, true), "other project prefix missing: " .. tostring(other_row))

print("OK session_preview")
