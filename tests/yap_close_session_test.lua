-- E2E: the close_session tool wipes the buffer only after the turn has fully
-- completed and the session file has been saved. The reply streams out, the
-- file is written, then the buffer is deleted — so "close the session when
-- done" works as a tool call and the conversation stays resumable from disk.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local state = require("harness.state")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

-- The close_session tool should use the same fallback order as :bd.
local waiting = yap.new()
state.awaiting[waiting] = true
local running = yap.new()
state.running[running] = { kill = function() end }

-- Replace the typing line under the LAST # @user heading.
local function set_prompt(b, text)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i] == "# @user" then
      vim.api.nvim_buf_set_lines(b, i, -1, false, { text })
      return
    end
  end
end

local function current()
  return vim.api.nvim_get_current_buf()
end

local buf = yap.new()
set_prompt(buf, "when you are done, close the session")
local path = vim.api.nvim_buf_get_name(buf)
assert(path ~= "" and vim.fn.filereadable(path) == 1, "session file missing up front")

local notifications = {}
local old_notify = vim.notify
vim.notify = function(message)
  notifications[#notifications + 1] = message
end

yap.send()
vim.cmd("enew") -- completion happens in the background; close_session should still stay quiet

-- The buffer must be wiped only after the turn completes.
local closed = vim.wait(30000, function()
  return not vim.api.nvim_buf_is_valid(buf) and current() == waiting
end, 50)
vim.notify = old_notify
assert(closed, "buffer not closed onto the waiting session after close_session turn")
assert(#notifications == 0, "close_session turn should not notify: " .. vim.inspect(notifications))

-- The session file survives (saved, not deleted) and holds the streamed
-- final answer plus the close_session tool block.
assert(vim.fn.filereadable(path) == 1, "session file deleted (should be saved, not deleted)")
local text = table.concat(vim.fn.readfile(path), "\n")
assert(text:match("Done%. Closing%."), "final answer missing from saved session: " .. text)
assert(
  text:match("close_session") and text:match("close requested"),
  "tool block missing from saved session: " .. text
)

print("OK close_session")
