-- `a` on the guard board toggles auto-accept: it sweeps any parked approvals
-- as Run, shows the mode in the board's winbar, and (until toggled off) answers
-- incoming approval requests Run immediately instead of parking them.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})
local state = require("harness.state")
local guard = require("harness.ui.guard")

local chat = yap.new()
vim.api.nvim_buf_set_lines(chat, -1, -1, false, { "try auto-accept" })

local function board_text()
  return table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr("Yap Guard"), 0, -1, false), "\n")
end

-- The counts and the auto-accept marker live in the board's winbar, which is a
-- `%!` expression rather than buffer text; call the renderer directly.
local function bar_text()
  return guard.winbar()
end

-- Park an approval with no backend so the `a` sweep clears it without
-- recording a settled row in the board history (which would pollute the later
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
assert(vim.fn.bufname(board) == "Yap Guard", "guard board did not open")
-- The cwd and the counts ride the window chrome, so the board window carries a
-- guard winbar and the shortcut line as its statusline.
local board_win = vim.api.nvim_get_current_win()
assert(vim.wo[board_win].winbar:find("guard'.winbar()", 1, true), "board window has no guard winbar")
assert(vim.wo[board_win].statusline:find("auto-accept", 1, true), "board window has no shortcut statusline")
assert(bar_text():find(vim.fs.normalize(vim.fn.getcwd()), 1, true), "winbar missing the cwd: " .. bar_text())
assert(bar_text():find("Parked 1", 1, true), "winbar missing parked approval count: " .. bar_text())
assert(not bar_text():find("auto-accept on", 1, true), "auto-accept marker shown while off")

-- `a` toggles on and sweeps the parked approval.
vim.api.nvim_feedkeys("a", "mtx", false)
assert(state.auto_accept == true, "`a` did not enable auto-accept")
assert(state.pending_approvals[chat] == nil, "auto-accept did not sweep the parked approval")
local text = board_text()
assert(bar_text():find("auto-accept on", 1, true), "winbar missing auto-accept marker after toggle on")
assert(not text:find("sweep me", 1, true), "swept approval still listed: " .. text)

-- `a` toggles off and the marker leaves the winbar.
vim.api.nvim_feedkeys("a", "mtx", false)
assert(state.auto_accept == false, "`a` did not disable auto-accept")
assert(not bar_text():find("auto-accept on", 1, true), "auto-accept marker shown while off")

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

-- The winbar still shows the mode is on after the live turn.
guard.toggle()
assert(bar_text():find("auto-accept on", 1, true), "winbar missing auto-accept marker after live turn")

guard.toggle() -- close
print("OK guard auto-accept")
