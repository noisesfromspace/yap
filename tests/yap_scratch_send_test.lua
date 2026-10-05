local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

local buf = yap.new()

local function lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function text(b)
  return table.concat(lines(b), "\n")
end

-- A queued send consumes the first live-buffer entry. A deliberately stale
-- file snapshot must not influence the message that is dispatched.
yap.scratch_toggle()
local scratch = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {
  "# @notes", "remember this", "", "# @steer", "", "# @queue", "stale disk task",
})
vim.cmd("write")
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {
  "# @notes", "remember this", "", "# @steer", "", "# @queue", "task one", "task two",
})
yap.scratch_send(scratch)
local current = text(scratch)
assert(current:match("task two") and not current:match("task one"), "dispatch did not consume the first live queue entry:\n" .. current)

-- After the first turn, the remaining queue item is NOT dispatched
-- automatically: it stays queued until an explicit <C-s>.
local done = vim.wait(15000, function()
  return not yap.is_running(buf) and text(buf):match("# @assistant") ~= nil
end, 100)
assert(done, "first queued item did not run:\n" .. text(buf))
local chat = text(buf)
assert(chat:match("task one") and not chat:match("task two"), "queue auto-dispatched the second item:\n" .. chat)
assert(text(scratch):match("task two"), "remaining queue entry was consumed prematurely")

-- A second <C-s> dispatches the remaining entry.
yap.scratch_send(scratch)
local done2 = vim.wait(15000, function()
  return not yap.is_running(buf) and text(buf):match("task two") ~= nil
end, 100)
assert(done2, "second queued item did not run:\n" .. text(buf))
local chat2 = text(buf)
assert(chat2:match("task one") and chat2:match("task two"), "live queue entries missing from chat:\n" .. chat2)
assert(not chat2:match("stale disk task"), "dispatch read stale saved file contents")
local saved = table.concat(vim.fn.readfile(vim.api.nvim_buf_get_name(scratch)), "\n")
assert(not saved:match("task one") and not saved:match("task two"), "consumed queue entries reappeared in saved file")
assert(saved:match("# @notes") and saved:match("# @queue"), "scratch section structure was not saved")

print("OK scratch_send")
