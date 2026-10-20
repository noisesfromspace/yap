-- A parked approval is the board's focus: the cursor lands on the newest one,
-- it is unfolded, and every other entry (older approvals, settled history) is
-- folded. Answering it leaves the next approval (or history) to take over.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local state = require("harness.state")
local paths = require("harness.path")
local guard = require("harness.ui.guard")

local a = yap.new({ provider = "mock", model = "m1" })
local b = yap.new({ provider = "mock", model = "m1" })

local function park(buf, id, reason, secs)
  state.running[buf] = {}
  state.pending_approvals[buf] = {
    id = id,
    tool = "bash",
    command = vim.json.encode({ command = "echo " .. id }),
    reason = reason,
    ts = os.date("%Y-%m-%dT%H:%M:%S", os.time() + secs),
  }
end

-- One settled history row so the board has a non-approval entry to fold.
local log = paths.audit_path(a)
vim.fn.mkdir(vim.fn.fnamemodify(log, ":h"), "p")
local now = os.time()
vim.fn.writefile({
  vim.json.encode({
    type = "approval_request",
    id = "h",
    tool = "bash",
    command = '{"command":"echo h"}',
    reason = "history-row",
    ts = os.date("%Y-%m-%dT%H:%M:%S", now + 100),
  }),
  vim.json.encode({ type = "approval_result", id = "h", approved = false, ts = os.date("%Y-%m-%dT%H:%M:%S", now + 100) }),
}, log, "a")

-- Two parked approvals (one per session): the newer is the focus, the older
-- folds away with the history row.
park(a, "older", "other-approval", 0)
park(b, "newer", "focus-me", 1)

guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(board) == "yap://guard", "board did not open")

local function line_of(reason)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(board, 0, -1, false)) do
    if l:find(reason, 1, true) then
      return i
    end
  end
  return nil
end

local focus = line_of("focus-me")
local other = line_of("other-approval")
local hist = line_of("history-row")
assert(focus and other and hist, "expected rows missing")

-- The cursor is on the newest parked approval.
local cur = vim.api.nvim_win_get_cursor(0)[1]
assert(cur == focus, ("cursor not on the parked approval: %d vs %d"):format(cur, focus))

-- That approval is unfolded; every other entry is folded.
assert(vim.fn.foldclosed(focus) == -1, "focus approval should be unfolded")
assert(vim.fn.foldclosed(other) ~= -1, "older approval should be folded")
assert(vim.fn.foldclosed(hist) ~= -1, "history row should be folded")

-- A refresh re-focuses the approval even if the cursor was moved away.
vim.api.nvim_win_set_cursor(0, { hist, 0 })
guard.touch()
assert(vim.api.nvim_win_get_cursor(0)[1] == focus, "refresh did not re-focus the parked approval")

guard.toggle() -- close
state.pending_approvals[a] = nil
state.pending_approvals[b] = nil
state.running[a] = nil
state.running[b] = nil
print("OK guard focus")
