-- Session picker previews: :YapInstances (live buffers) and :YapSessions
-- (saved files) preview the same two excerpts — the initial # @user
-- message and the last # @assistant answer — instead of the raw item.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local session = require("harness.session")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

-- preview_lines extracts the first user block and the last assistant block,
-- headings excluded, surrounding blank lines trimmed.
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
local preview = session.preview_lines(convo)
assert(preview[1] == "Initial user message:", "unexpected preview: " .. vim.inspect(preview))
assert(preview[2] == "first question" and preview[3] == "second line",
  "first user message wrong: " .. vim.inspect(preview))
assert(preview[#preview - 1] == "last answer line 1" and preview[#preview] == "last answer line 2",
  "last agent answer wrong: " .. vim.inspect(preview))
assert(session.preview_lines({})[1] == "(no messages yet)", "empty preview missing")

-- :YapInstances previews the live buffer with the same excerpts.
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @user", "", "hello", "", "# @assistant", "", "bye" })
local captured
local orig_select = vim.ui.select
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.instances()
vim.ui.select = orig_select
assert(captured and #captured.items == 1, "expected one open session: " .. vim.inspect(captured and captured.items))
assert(type(captured.opts.preview_item) == "function", "instances preview_item missing")
local live_preview = captured.opts.preview_item(captured.items[1])
assert(live_preview[1] == "Initial user message:" and live_preview[2] == "hello",
  "instances preview wrong: " .. vim.inspect(live_preview))
assert(live_preview[#live_preview] == "bye", "instances last answer wrong: " .. vim.inspect(live_preview))

-- Open child sessions are explicitly identified by their subagent role.
local child = yap.new({ role = "scout", hidden = true })
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.instances()
vim.ui.select = orig_select
local child_item
for _, item in ipairs(captured.items) do
  if item.buf == child then child_item = item; break end
end
assert(child_item and child_item.text:find("[subagent: scout]", 1, true),
  "subagent role missing from instances label: " .. vim.inspect(child_item))

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
local saved_preview = captured.opts.preview_item(captured.items[1])
assert(saved_preview[1] == "Initial user message:" and saved_preview[2] == "history question",
  "saved preview wrong: " .. vim.inspect(saved_preview))
assert(saved_preview[#saved_preview] == "history answer", "saved last answer wrong: " .. vim.inspect(saved_preview))

print("OK session_preview")
