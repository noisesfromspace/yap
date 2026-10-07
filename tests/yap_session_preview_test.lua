-- Session picker previews: open-session picker and :YapSessions
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

-- The open-session picker previews another live buffer with the same excerpts.
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @user", "", "hello", "", "# @assistant", "", "bye" })
yap.new() -- current session is included in the general picker
local captured
local orig_select = vim.ui.select
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
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

-- Open child sessions are a separate picker row, indented beneath their parent.
local child = yap.new({ role = "scout", hidden = true })
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
  rendered_child:find("↳ scout · inspect this task", 1, true) and not rendered_child:find(vim.fn.getcwd(), 1, true)
    and not rendered_child:find("(m1)", 1, true),
  "child row wastes space: " .. rendered_child
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

-- :YapSessions previews the saved file with the same excerpts.
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
  "history answer",
})
session.save(saved)
local path = vim.b[saved].yap_path
assert(path and vim.fn.filereadable(path) == 1, "session not saved")
local saved_child = yap.new({ role = "scout", system = "Scout role", hidden = true })
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

-- A named parent keeps its auto-named children in renamed history, while a
-- custom-named orphan child is discoverable as a typed root.
local dir = require("harness.path").session_dir(vim.fn.getcwd())
local named_parent = yap.new({ path = dir .. "/named-history-parent.md" })
local named_parent_path = vim.b[named_parent].yap_path
local named_child = yap.new({ role = "scout", hidden = true })
local named_child_path = vim.b[named_child].yap_path
vim.api.nvim_buf_set_lines(named_child, -1, -1, false, { "original task", "", "# @assistant", "", "done", "", "# @user", "", "follow-up task" })
vim.api.nvim_buf_set_lines(named_child, 3, 3, false, { "description: Generated follow-up description", "subagent_parent: " .. named_parent_path })
session.save(named_child)
vim.api.nvim_buf_set_lines(named_parent, 3, 3, false, { "subagents:", "  - " .. named_child_path })
session.save(named_parent)
local orphan = yap.new({ path = dir .. "/named-history-orphan.md", role = "scout", hidden = true })
local orphan_path = vim.b[orphan].yap_path
vim.api.nvim_buf_set_lines(orphan, -1, -1, false, { "orphan task" })
session.save(orphan)
local renamed = session.list("renamed")
local positions = {}
for i, item in ipairs(renamed) do
  positions[item.path] = i
end
assert(positions[named_parent_path] and positions[named_child_path] == positions[named_parent_path] + 1,
  "renamed parent lost its child: " .. vim.inspect(renamed))
assert(renamed[positions[named_child_path]].text == "  ↳ scout · Generated follow-up description",
  "saved child should prefer its description over the task: " .. vim.inspect(renamed))
vim.api.nvim_set_current_buf(named_parent)
local live_named
vim.ui.select = function(items, opts)
  live_named = { items = items, format = opts.format_item }
end
yap.instances()
vim.ui.select = orig_select
for _, item in ipairs(live_named.items) do
  if item.buf == named_child then
    assert(item.text == "↳ scout · Generated follow-up description", "open child should prefer its description: " .. item.text)
    assert(not live_named.format(item):find("(m1)", 1, true), "open subagent row repeats its model")
  end
end
assert(positions[orphan_path] and renamed[positions[orphan_path]].text == "scout · orphan task (parent not shown)",
  "named orphan subagent missing from renamed history: " .. vim.inspect(renamed))

-- The history picker annotates saved sessions that are open with their live
-- state, including a manually stopped turn.
local state = require("harness.state")
local icons = yap.config.icons
local function history_status(expected)
  captured = nil
  vim.ui.select = function(items, opts)
    captured = { items = items, opts = opts }
  end
  yap.history()
  vim.ui.select = orig_select
  local item
  for _, candidate in ipairs(captured and captured.items or {}) do
    if candidate.path == path then
      item = candidate
    end
  end
  assert(item, "expected saved history row: " .. vim.inspect(captured))
  local rendered = captured.opts.format_item(item)
  assert(rendered:find(expected, 1, true), "history row missing " .. expected .. ": " .. rendered)
end
state.running[saved] = {}
history_status(icons.running .. " running")
state.running[saved] = nil
state.awaiting[saved] = true
history_status(icons.waiting .. " waiting")
state.stopped[saved] = true
history_status(icons.stopped .. " stopped")
state.awaiting[saved], state.stopped[saved] = nil, nil

print("OK session_preview")
