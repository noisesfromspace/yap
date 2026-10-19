-- A parked approval is non-blocking: it notifies (distinctly) instead of
-- popping a modal, the guard board shows it, Inspect focuses the matching
-- tool region, and Deny (the board's answer path) continues the turn.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local chat = yap.new()
vim.api.nvim_buf_set_lines(chat, -1, -1, false, { "try ssh" })

local notifications = {}
local old_notify = vim.notify
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
end

local state = require("harness.state")
local guard = require("harness.guard")
yap.send()
assert(
  vim.wait(10000, function()
    return state.pending_approvals[chat] ~= nil
  end, 50),
  "approval did not park the turn"
)

-- The notification must be unmistakable but lean: ERROR level, a dedicated
-- title and shield icon, and no full call — that belongs in the board and
-- audit, never a modal confirm().
local function approval_notice()
  for _, n in ipairs(notifications) do
    if n.opts and n.opts.title == "yap approval required" then
      return n
    end
  end
end
local notice = approval_notice()
assert(notice, "no approval notification fired")
assert(notice.level == vim.log.levels.ERROR, "approval notification not ERROR level")
assert(notice.opts.icon == yap.config.icons.approval, "approval notification missing shield icon")
assert(not notice.msg:find("rm -rf /", 1, true), "notification should not dump the full call")
assert(notice.msg:find("needs approval", 1, true), "notification should state approval is required")
assert(not notice.msg:find("Run, Deny or Inspect", 1, true), "notification should not contain instructions")
assert(not notice.msg:find(":YapGuard", 1, true), "notification should not contain the command")

-- The board lists the parked approval with its decoded command and reason.
guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(board) == "yap://guard", "guard board did not open")
local text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("recursive deletion of critical paths", 1, true), "board missing approval reason")
guard.toggle() -- close (defer)

-- Inspect focuses the session's tool region without touching the parked
-- approval: it navigates the session, never a modal or the audit log.
guard.toggle()
local board = vim.fn.bufnr("yap://guard")
local row_line
for i, l in ipairs(vim.api.nvim_buf_get_lines(board, 0, -1, false)) do
  if l:find("recursive deletion of critical paths", 1, true) then
    row_line = i
    break
  end
end
assert(row_line, "approval row not found on the board")
vim.api.nvim_win_set_cursor(0, { row_line, 0 })
vim.api.nvim_feedkeys("i", "mtx", false)
assert(vim.api.nvim_get_current_buf() == chat, "Inspect did not focus the session")
assert(state.pending_approvals[chat] ~= nil, "Inspect cleared the pending approval")

-- Deny continues the turn.
yap.answer_approval(chat, false)
assert(state.pending_approvals[chat] == nil, "Deny left the approval pending")
assert(
  vim.wait(10000, function()
    return table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), "\n"):find("Denied as requested.", 1, true)
  end, 50),
  "turn did not continue after denial"
)

vim.notify = old_notify
print("OK approval inspect")
