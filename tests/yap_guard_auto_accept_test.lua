-- `a` on the guard board toggles auto-accept: it sweeps any parked approvals
-- as Run, shows the mode in the header, and (until toggled off) answers
-- incoming approval requests Run immediately instead of parking them.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local state = require("harness.state")
local guard = require("harness.guard")

local chat = yap.new()
vim.api.nvim_buf_set_lines(chat, -1, -1, false, { "try auto-accept" })

local function board_text()
  return table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr("yap://guard"), 0, -1, false), "\n")
end

-- Park an approval with no backend so the `a` sweep clears it without
-- appending a settled row to the audit log (which would pollute the later
-- real-turn assertions).
state.pending_approvals[chat] = {
  id = "sweep-me",
  tool = "bash",
  command = vim.json.encode({ command = "echo sweep" }),
  reason = "sweep me",
  ts = os.date("%Y-%m-%dT%H:%M:%S"),
}

guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(board) == "yap://guard", "guard board did not open")
local text = board_text()
assert(text:find("Parked 1", 1, true), "header missing parked approval count")
assert(not text:find("auto-accept on", 1, true), "auto-accept marker shown while off")

-- `a` toggles on and sweeps the parked approval.
vim.api.nvim_feedkeys("a", "mtx", false)
assert(state.auto_accept == true, "`a` did not enable auto-accept")
assert(state.pending_approvals[chat] == nil, "auto-accept did not sweep the parked approval")
text = board_text()
assert(text:find("auto-accept on", 1, true), "header missing auto-accept marker after toggle on")
assert(not text:find("sweep me", 1, true), "swept approval still listed: " .. text)

-- `a` toggles off and the marker leaves the header.
vim.api.nvim_feedkeys("a", "mtx", false)
assert(state.auto_accept == false, "`a` did not disable auto-accept")
text = board_text()
assert(not text:find("auto-accept on", 1, true), "auto-accept marker shown while off")

-- Back on for the live turn: an incoming approval is answered immediately.
vim.api.nvim_feedkeys("a", "mtx", false)
assert(state.auto_accept == true, "`a` did not re-enable auto-accept")
guard.toggle() -- close
vim.api.nvim_set_current_buf(chat)

yap.send(chat)
assert(
  vim.wait(10000, function()
    return table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), "\n"):find("Approved and ran.", 1, true)
  end, 50),
  "turn did not complete after auto-accept"
)
assert(state.pending_approvals[chat] == nil, "auto-accept left the approval parked")

-- The answered approval's rule is listed, and the header still shows the
-- mode is on.
guard.toggle()
text = board_text()
assert(text:find("auto-accept on", 1, true), "header missing auto-accept marker after live turn")
assert(text:find("system power control", 1, true), "static rule missing its name: " .. text)

guard.toggle() -- close
print("OK guard auto-accept")
