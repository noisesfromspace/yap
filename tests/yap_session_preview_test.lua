-- Session picker previews: :YapInstances (live buffers) and :YapSessions
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
  assert(type(result) == "table" and result.buf and vim.api.nvim_buf_is_valid(result.buf),
    "preview must return a { buf = ... } table: " .. vim.inspect(result))
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
assert(lines[3] == "first question" and lines[4] == "second line",
  "first user message wrong: " .. vim.inspect(lines))
assert(lines[6] == "---" and lines[8] == "## Last answer",
  "separator / answer heading wrong: " .. vim.inspect(lines))
assert(lines[10] == "last answer line 1" and lines[11] == "last answer line 2",
  "last agent answer wrong: " .. vim.inspect(lines))
assert(preview_text(session.preview({}))[1] == "(no messages yet)", "empty preview missing")

-- :YapInstances previews another live buffer with the same excerpts.
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @user", "", "hello", "", "# @assistant", "", "bye" })
yap.new() -- current session is omitted from the picker
local captured
local orig_select = vim.ui.select
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.instances()
vim.ui.select = orig_select
assert(captured and #captured.items == 1 and captured.items[1].buf == buf,
  "expected only the other open session: " .. vim.inspect(captured and captured.items))
assert(type(captured.opts.preview_item) == "function", "instances preview_item missing")
local live_preview = preview_text(captured.opts.preview_item(captured.items[1]))
assert(live_preview[1] == "## First message" and live_preview[3] == "hello",
  "instances preview wrong: " .. vim.inspect(live_preview))
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
  if item.buf == buf then parent_item = item end
  if item.buf == child then child_item = item end
end
assert(parent_item and not parent_item.text:find("\n", 1, true),
  "current parent with an open subagent should have its own picker row: " .. vim.inspect(parent_item))
assert(child_item and child_item.text == "  ↳ scout: inspect this task",
  "subagent should have a separate indented row: " .. vim.inspect(child_item))

-- Waiting subagents are available through their parent in :YapWaiting, not
-- as a separate entry. The general session picker still lists them above.
local state = require("harness.state")
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
assert(captured and #captured.items == 1 and captured.items[1].buf == buf,
  "waiting picker should show the parent but not its subagent: " .. vim.inspect(captured and captured.items))
state.awaiting[buf], state.awaiting[child] = nil, nil

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

captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
session.pick({ scope = "cwd" }, function() end)
vim.ui.select = orig_select
assert(captured and #captured.items == 1, "expected one saved session: " .. vim.inspect(captured and captured.items))
assert(type(captured.opts.preview_item) == "function", "saved preview_item missing")
local saved_preview = preview_text(captured.opts.preview_item(captured.items[1]))
assert(saved_preview[1] == "## First message" and saved_preview[3] == "history question",
  "saved preview wrong: " .. vim.inspect(saved_preview))
assert(saved_preview[#saved_preview] == "history answer", "saved last answer wrong: " .. vim.inspect(saved_preview))

print("OK session_preview")
