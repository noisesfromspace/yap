-- A parked approval is non-blocking: it notifies (distinctly) instead of
-- popping a modal, then :YapApproval answers it through a Run/Deny/Inspect
-- picker. Inspect can be repeated; the audit and conversation stay visible
-- side by side, and :only from either window must not strand the user.
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

-- Answer the picker: Inspect three times, then Deny.
local picks = {}
local actions = { "Inspect", "Inspect", "Inspect", "Deny" }
local ai = 0
local action_preview
local old_select = vim.ui.select
vim.ui.select = function(items, opts, cb)
  picks[#picks + 1] = vim.deepcopy(items)
  if type(items[1]) == "string" then
    ai = ai + 1
    action_preview = opts and opts.preview_item and opts.preview_item()
    cb(actions[ai])
  else
    cb(items[1]) -- multi-approval chooser (not hit here)
  end
end

local state = require("harness.state")
yap.send()
assert(
  vim.wait(10000, function()
    return state.pending_approvals[chat] ~= nil
  end, 50),
  "approval did not park the turn"
)

-- The notification must be unmistakable but lean: ERROR level, a dedicated
-- title and shield icon, and no full call — that belongs in the picker
-- preview and audit, never a modal confirm().
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

vim.cmd("YapApproval") -- Inspect
assert(vim.deep_equal(picks[1], { "Run", "Deny", "Inspect" }), "picker lacks Run/Deny/Inspect: " .. vim.inspect(picks[1]))
assert(action_preview and vim.api.nvim_buf_is_valid(action_preview.buf), "action picker preview missing")
assert(
  table.concat(vim.api.nvim_buf_get_lines(action_preview.buf, 0, -1, false), "\n"):find("rm -rf /", 1, true),
  "preview lost the full call"
)
vim.api.nvim_buf_delete(action_preview.buf, { force = true })
local audit = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(audit):match("%-audit$"), "Inspect should focus the audit")
assert(vim.fn.win_findbuf(chat)[1], "conversation should remain visible beside audit")
local line = vim.api.nvim_win_get_cursor(0)[1]
local entry = vim.api.nvim_buf_get_lines(audit, line - 1, line, false)[1]
assert(
  entry:find("approval requested", 1, true) and entry:find("rm -rf /", 1, true),
  "Inspect did not show blocked call"
)
assert(vim.fn.foldclosed(line) == -1, "blocked call hidden in fold")
-- The request should not be a lone folded summary: its audit context is
-- visible on adjacent lines, including the earlier event from this call.
local context = table.concat(vim.api.nvim_buf_get_lines(audit, math.max(line - 4, 0), line - 1, false), "\n")
assert(context:find("• bash rm -rf /", 1, true), "blocked tool call missing before shield request")
local log = require("harness.path").audit_path(chat)
local function count(event)
  local n = 0
  for _, raw in ipairs(vim.fn.readfile(log)) do
    local ok, ev = pcall(vim.json.decode, raw)
    if ok and ev.type == event then
      n = n + 1
    end
  end
  return n
end
assert(count("approval_result") == 0, "Inspect answered the call")
assert(state.pending_approvals[chat] ~= nil, "Inspect cleared the pending approval")
-- Keep only the audit window: the deferred BufWinLeave cleanup must not
-- replace the approval review with an empty buffer.
vim.cmd("only")
vim.wait(200)
assert(vim.api.nvim_get_current_buf() == audit, ":only from audit lost the review")
vim.cmd("YapApproval") -- Inspect again, restore the conversation beside the audit
assert(vim.api.nvim_get_current_buf() == audit, "Inspect could not be repeated")
assert(vim.fn.win_findbuf(chat)[1], "repeat Inspect did not restore conversation")
vim.api.nvim_set_current_win(assert(vim.fn.win_findbuf(chat)[1]))
vim.cmd("only")
assert(vim.api.nvim_get_current_buf() == chat, ":only from chat left an empty buffer")
vim.cmd("YapApproval") -- Inspect again from the chat, then Deny from the audit
assert(vim.api.nvim_get_current_buf() == audit, "third Inspect failed")
vim.cmd("YapApproval")
assert(
  vim.wait(10000, function()
    return count("approval_result") == 1
  end, 50),
  "Deny did not answer"
)
assert(state.pending_approvals[chat] == nil, "Deny left the approval pending")
assert(
  vim.wait(10000, function()
    return table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), "\n"):find("Denied as requested.", 1, true)
  end, 50),
  "turn did not continue after denial"
)
assert(count("approval_request") == 1 and count("approval_result") == 1, "approval trail missing")
vim.notify = old_notify
vim.ui.select = old_select
print("OK approval inspect")
