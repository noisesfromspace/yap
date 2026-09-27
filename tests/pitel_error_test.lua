local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("pitel")

-- 1. parse excludes error regions (and thinking)
local buf = pitel.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user", "", "q", "",
  "# @assistant", "",
  "<!-- pitel:error", "pitel: 401: unauthorized", "-->", "",
  "partial answer", "",
  "# @user", "",
})
local msgs = pitel.parse_buffer(buf)
assert(msgs[2].content == "partial answer", "error region leaked: " .. vim.inspect(msgs[2].content))

-- 2. real send against missing provider -> error surfaces in winbar + buffer
local buf2 = pitel.new({ provider = "nosuch", model = "m" })
vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "# @user", "", "hi" })
local notified = nil
local orig_notify = vim.notify
vim.notify = function(msg, level) notified = { msg = msg, level = level } end
pitel.send()
local done = vim.wait(5000, function() return notified ~= nil end, 50)
vim.notify = orig_notify
assert(done, "no error notification within 5s")
assert(notified.level == vim.log.levels.ERROR, "notify level not ERROR")
assert(notified.msg:match('unknown provider "nosuch"'), "unexpected notify: " .. notified.msg)
local bar = pitel.winbar(buf2)
assert(bar:match("error") and bar:match("PitelError"), "winbar has no error state: " .. bar)
local text = table.concat(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), "\n")
assert(text:match("<!%-%- pitel:error"), "no error marker in buffer")
-- next parse excludes the error
local msgs2 = pitel.parse_buffer(buf2)
for _, m in ipairs(msgs2) do
  assert(not m.content:match("unknown provider"), "error text leaks into messages")
end
-- 3. winbar error clears on next send attempt start (will fail again, but transiently clears)
print("OK")
