-- A live tail must not outlive its session: closing the session wipes the tail
-- with it, and a tail buffer is never resolved back to a dead session buffer
-- id (`q` in an orphaned tail raised "Invalid buffer id" from display_path).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local audit = require("harness.client.audit")
local sessions = require("harness.session.sessions")
yap.setup({ bin = ROOT .. "/yap" })

local buf = yap.new()
local chat = vim.api.nvim_get_current_win()
yap.live()
local tail = vim.api.nvim_get_current_buf()
assert(tail == sessions.tail_buffer(buf), "live did not open the session tail")

-- A stale owner key (a buffer id that no longer exists) is skipped, so the
-- tail still resolves to its live session instead of erroring.
audit.views()[999999] = { bufnr = tail }
assert(sessions.session_of(tail) == buf, "stale tail owner key was not skipped")

-- Closing the session (bufhidden=wipe) takes the tail with it.
vim.api.nvim_set_current_win(chat)
vim.api.nvim_buf_delete(buf, { force = true })
assert(not vim.api.nvim_buf_is_valid(tail), "tail outlived its session")
assert(audit.view(buf) == nil, "tail state outlived its session")
assert(pcall(sessions.live, tail), "closing a dead tail errored")
print("OK tail lifetime")
