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

-- A steer submitted during a final-answer stream has no further model
-- boundary. It stays in scratch and does not start a surprise follow-up.
local late = yap.new()
vim.api.nvim_buf_set_lines(late, -1, -1, false, { "final answer with no tools" })
assert(yap.send(late), "late-steer turn did not start")
yap.scratch_toggle(late)
local late_scratch = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(late_scratch, 0, -1, false, {
  "# @notes", "", "# @steer", "late instruction", "", "# @queue",
})
local late_notices = {}
local original_notify = vim.notify
vim.notify = function(msg, ...)
  late_notices[#late_notices + 1] = msg
  return original_notify(msg, ...)
end
yap.scratch_send(late_scratch)
assert(vim.wait(15000, function() return not yap.is_running(late) end, 100), "late-steer turn did not finish")
vim.notify = original_notify
assert(table.concat(late_notices, "\n"):find("steer was not delivered", 1, true), "late steer had no warning")
assert(text(late_scratch):find("late instruction", 1, true), "undelivered steer was consumed")
assert(not text(late):find("late instruction", 1, true), "undelivered steer was sent to chat")
assert(not text(late):find("# @assistant", text(late):find("# @assistant", 1, true) + 1, true), "late steer auto-dispatched")

-- Stopping a running turn must likewise keep the draft for an explicit send.
local stopped = yap.new()
vim.api.nvim_buf_set_lines(stopped, -1, -1, false, { "stop before completion" })
assert(yap.send(stopped), "stop-steer turn did not start")
yap.scratch_toggle(stopped)
local stop_scratch = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(stop_scratch, 0, -1, false, {
  "# @notes", "", "# @steer", "unfinished instruction", "", "# @queue",
})
local stop_notices = {}
vim.notify = function(msg, ...)
  stop_notices[#stop_notices + 1] = msg
  return original_notify(msg, ...)
end
yap.scratch_send(stop_scratch)
yap.stop(stopped)
vim.notify = original_notify
assert(table.concat(stop_notices, "\n"):find("steer was not delivered", 1, true), "stopped steer had no warning")
assert(not yap.is_running(stopped), "stop did not stop the turn")
assert(text(stop_scratch):find("unfinished instruction", 1, true), "stop consumed pending steer")
assert(not text(stopped):find("unfinished instruction", 1, true), "stop sent pending steer")

-- A failed backend spawn must not consume the queued message on disk or
-- in the live scratch buffer.
yap.config.description_model = ""
yap.config.description_answer_model = ""
yap.config.bin = ROOT .. "/no-such-yap-binary"
local failed = yap.new()
yap.scratch_toggle(failed)
local failed_scratch = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(failed_scratch, 0, -1, false, {
  "# @notes", "", "# @steer", "", "# @queue", "keep this task",
})
vim.cmd("write")
yap.scratch_send(failed_scratch)
assert(text(failed_scratch):find("keep this task", 1, true), "failed send consumed live queue")
assert(table.concat(vim.fn.readfile(vim.api.nvim_buf_get_name(failed_scratch)), "\n"):find("keep this task", 1, true), "failed send consumed saved queue")

print("OK scratch_send, late steer, stop steer and failed send")
