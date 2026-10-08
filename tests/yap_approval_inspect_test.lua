-- A parked approval is non-blocking: it notifies (distinctly) instead of
-- popping a modal, the guard board shows it with full context, Inspect
-- focuses the audit entry, and Deny (the board's answer path) continues the
-- turn.
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
assert(notice.msg:find(":YapGuard", 1, true), "notification should point at :YapGuard")

-- The board lists the parked approval with its decoded command and reason.
guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(board) == "yap://guard", "guard board did not open")
local text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("▸ Open (1)", 1, true), "board Open section missing approval")
assert(text:find("recursive deletion of critical paths", 1, true), "board missing approval reason")
guard.toggle() -- close (defer)

-- Inspect focuses the shield-marked audit entry.
local paths = require("harness.path")
local ordinal = 0
local target
for _, line in ipairs(vim.fn.readfile(paths.audit_path(chat))) do
  local ok, ev = pcall(vim.json.decode, line)
  if ok and type(ev) == "table" and (ev.type == "alert_advisory" or ev.type == "approval_request") then
    ordinal = ordinal + 1
    if ev.type == "approval_request" then
      target = ordinal
    end
  end
end
assert(target, "no approval_request in audit log")
yap.reveal_audit(paths.session_path(chat), target)
local audit = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(audit):match("%-audit$"), "Inspect should focus the audit")
local line = vim.api.nvim_win_get_cursor(0)[1]
local entry = vim.api.nvim_buf_get_lines(audit, line - 1, line, false)[1]
assert(entry:find("approval requested", 1, true), "Inspect did not show blocked call")
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

-- The answered approval moves from Open to History, not vanish from the board.
guard.toggle()
local bboard = vim.fn.bufnr("yap://guard")
local btext = table.concat(vim.api.nvim_buf_get_lines(bboard, 0, -1, false), "\n")
assert(btext:find("▸ History", 1, true), "board missing History after denial: " .. btext)
assert(btext:find("recursive deletion of critical paths", 1, true), "denied approval vanished from History")
guard.toggle() -- close
vim.notify = old_notify
print("OK approval inspect")
