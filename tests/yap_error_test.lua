local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")

-- 1. parse excludes error regions (and thinking)
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user", "", "q", "",
  "# @assistant", "",
  "<!-- yap:error", "yap: 401: unauthorized", "-->", "",
  "partial answer", "",
  "# @user", "",
})
local msgs = yap.parse_buffer(buf)
assert(msgs[2].content == "partial answer", "error region leaked: " .. vim.inspect(msgs[2].content))

-- 2. real send against missing provider -> error surfaces in winbar + buffer
local buf2 = yap.new({ provider = "nosuch", model = "m" })
vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "# @user", "", "hi" })
local notified = nil
local orig_notify = vim.notify
vim.notify = function(msg, level) notified = { msg = msg, level = level } end
yap.send()
local done = vim.wait(5000, function() return notified ~= nil end, 50)
vim.notify = orig_notify
assert(done, "no error notification within 5s")
assert(notified.level == vim.log.levels.ERROR, "notify level not ERROR")
assert(notified.msg:match('unknown provider "nosuch"'), "unexpected notify: " .. notified.msg)
local bar = yap.winbar(buf2)
assert(bar:match("error") and bar:match("YapError"), "winbar has no error state: " .. bar)
local text = table.concat(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), "\n")
assert(text:match("<!%-%- yap:error"), "no error marker in buffer")
local err_lines = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
assert(err_lines[#err_lines - 1] == "# @user" and err_lines[#err_lines] == "",
  "failed stream did not end in a closed user block")
-- Errors surface in the unified session picker with an error status.
local pick_items
local orig_select = vim.ui.select
vim.ui.select = function(items) pick_items = items end
yap.instances()
vim.ui.select = orig_select
local found_error
for _, item in ipairs(pick_items or {}) do
  if item.buf == buf2 then
    found_error = item
  end
end
assert(found_error, "error session missing from session picker")
assert(found_error.status == "✗ error", "error status missing: " .. vim.inspect(found_error))
-- next parse excludes the error
local msgs2 = yap.parse_buffer(buf2)
for _, m in ipairs(msgs2) do
  assert(not m.content:match("unknown provider"), "error text leaks into messages")
end
-- 3. winbar error clears on next send attempt start (will fail again, but transiently clears)
print("OK")
