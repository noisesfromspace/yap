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

-- A queued send dispatches the ENTIRE # @queue body as one message. A
-- deliberately stale file snapshot must not influence what is dispatched.
yap.scratch_toggle()
local scratch = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {
  "# @notes",
  "remember this",
  "",
  "# @steer",
  "",
  "# @queue",
  "stale disk task",
})
vim.cmd("write")
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {
  "# @notes",
  "remember this",
  "",
  "# @steer",
  "follow up after queue",
  "",
  "# @queue",
  "task one",
  "task two",
})
yap.scratch_send(scratch)
local current = text(scratch)
assert(
  current:match("# @queue") and not current:match("task one") and not current:match("task two")
    and current:match("# @steer\nfollow up after queue"),
  "dispatch did not prioritize the queue and preserve steer:\n" .. current
)

-- The whole body arrives as a single turn; the queue is already empty, so
-- nothing is left to auto-dispatch afterward.
local done = vim.wait(15000, function()
  return not yap.is_running(buf) and text(buf):match("# @assistant") ~= nil
end, 100)
assert(done, "queued turn did not run:\n" .. text(buf))
local chat = text(buf)
assert(chat:match("task one") and chat:match("task two"), "queue body missing from chat:\n" .. chat)
assert(not chat:match("follow up after queue"), "steer ran ahead of the queue")
assert(not chat:match("stale disk task"), "dispatch read stale saved file contents")

-- Once the turn ends, <C-s> sends the steer body as a follow-up when the
-- queue is empty, and consumes only that section.
yap.scratch_send(scratch)
assert(not text(scratch):match("follow up after queue"), "idle steer was not consumed")
local steer_done = vim.wait(15000, function()
  return not yap.is_running(buf) and text(buf):match("# @assistant") ~= nil
    and text(buf):match("# @user\n\nfollow up after queue") ~= nil
end, 100)
assert(steer_done, "idle steer did not run:\n" .. text(buf))

-- A further <C-s> with both sections empty starts nothing.
yap.scratch_send(scratch)
assert(not yap.is_running(buf), "empty scratch dispatched a turn")
assert(
  text(scratch):match("# @queue") and not text(scratch):match("task"),
  "empty queue lost its heading:\n" .. text(scratch)
)

local saved = table.concat(vim.fn.readfile(vim.api.nvim_buf_get_name(scratch)), "\n")
assert(not saved:match("task one") and not saved:match("task two") and not saved:match("follow up after queue"), "consumed scratch text reappeared in saved file")
assert(saved:match("# @notes") and saved:match("# @queue"), "scratch section structure was not saved")

print("OK scratch_send")
