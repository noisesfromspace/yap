local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local document = require("harness.model.document")

-- 1. parse excludes error regions (and thinking)
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user",
  "",
  "q",
  "",
  "# @assistant",
  "",
  "<!-- yap:error",
  "yap: 401: unauthorized",
  "-->",
  "",
  "partial answer",
  "",
  "# @user",
  "",
})
local msgs = document.messages(buf)
assert(msgs[2].content == "partial answer", "error region leaked: " .. vim.inspect(msgs[2].content))

-- 2. real send against missing provider -> error surfaces in winbar + buffer
local buf2 = yap.new({ provider = "nosuch", model = "m" })
vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "# @user", "", "hi" })
-- Session titling runs on the same send and fails for the same reason (its
-- model group is unconfigured here), so collect notifications and look for
-- the send error instead of pinning the first one.
local notified = {}
local orig_notify = vim.notify
vim.notify = function(msg, level)
  notified[#notified + 1] = { msg = msg, level = level }
end
yap.send()
local done = vim.wait(5000, function()
  for _, n in ipairs(notified) do
    if n.msg:match('unknown provider "nosuch"') then
      return true
    end
  end
  return false
end, 50)
vim.notify = orig_notify
assert(done, "no send error notification within 5s: " .. vim.inspect(notified))
local send_err
for _, n in ipairs(notified) do
  if n.msg:match('unknown provider "nosuch"') then
    send_err = n
  end
end
assert(send_err.level == vim.log.levels.ERROR, "notify level not ERROR")
local bar = yap.winbar(buf2)
local icons = require("harness").config.icons
assert(bar:find("%#YapError#" .. icons.error, 1, true), "winbar has no error state: " .. bar)
local text = table.concat(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), "\n")
assert(text:match("<!%-%- yap:error"), "no error marker in buffer")
assert(not text:find("# @assistant", 1, true), "failed turn left a phantom assistant reply: " .. text)
assert(text:match("# @user\n\nhi$"), "failed turn did not restore the sent prompt: " .. text)
-- Errors surface in the unified session picker with an error status icon.
-- The active session is intentionally omitted, so inspect from another buffer.
vim.cmd("enew")
local pick_items
local orig_select = vim.ui.select
vim.ui.select = function(items, opts)
  pick_items = { items = items, format = opts.format_item }
end
yap.sessions()
vim.ui.select = orig_select
local found_error
for _, item in ipairs(pick_items.items or {}) do
  if vim.fs.normalize(item.path) == vim.fs.normalize(vim.b[buf2].yap_path) then
    found_error = item
  end
end
assert(found_error, "error session missing from session picker")
assert(
  vim.startswith(pick_items.format(found_error), icons.error),
  "error status icon missing: " .. pick_items.format(found_error)
)
-- next parse excludes the error
local msgs2 = document.messages(buf2)
assert(msgs2[#msgs2].content == "hi", "failed prompt was not restored: " .. vim.inspect(msgs2))
for _, m in ipairs(msgs2) do
  assert(not m.content:match("unknown provider"), "error text leaks into messages")
end
-- An error remains visible after reopening, while the draft still sends cleanly.
local path = vim.b[buf2].yap_path
vim.api.nvim_buf_delete(buf2, { force = true })
local reopened = yap.open(path)
assert(require("harness.ui.picker").state(reopened) == "error", "reopened error lost its status")
assert(document.messages(reopened)[#document.messages(reopened)].content == "hi", "reopened retry prompt changed")
print("OK")
