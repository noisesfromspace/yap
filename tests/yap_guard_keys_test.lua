-- Direct row keys on the guard board: r/x run/deny the approval under the
-- cursor without opening the transient, and i is bound for every row. Rule
-- rows are informational (r/x/i are no-ops there).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})
local state = require("harness.state")
local guard = require("harness.ui.guard")

local a = yap.new({ provider = "mock", model = "m1" })

local function park(buf, id, tool, command, reason)
  state.running[buf] = {}
  state.pending_approvals[buf] = {
    id = id,
    tool = tool,
    command = vim.json.encode({ command = command }),
    reason = reason,
    ts = os.date("%Y-%m-%dT%H:%M:%S"),
  }
end

local function row_line(board, reason)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(board, 0, -1, false)) do
    if l:find(reason, 1, true) then
      return i
    end
  end
  return nil
end

park(a, "key-1", "bash", "rm -rf /", "direct-run")

guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.fn.bufname(board) == "Yap Guard", "guard board did not open")

for _, key in ipairs({ "r", "x", "i", "Y", "c" }) do
  local m = vim.fn.maparg(key, "n", false, true)
  assert(m and m.buffer == 1, "guard board missing direct '" .. key .. "' keymap")
end

-- Y copies the full command from a folded bash approval to both registers.
vim.fn.setreg('"', "old unnamed")
vim.fn.setreg("+", "old clipboard")
vim.api.nvim_feedkeys("Y", "mtx", false)
assert(vim.fn.getreg('"') == "rm -rf /", "Y did not copy the bash command to the unnamed register")
assert(vim.fn.getreg("+") == "rm -rf /", "Y did not copy the bash command to the clipboard register")

-- r on the cursor row (already the first approval row) approves directly.
vim.api.nvim_feedkeys("r", "mtx", false)
assert(state.pending_approvals[a] == nil, "r did not approve the approval under the cursor")

-- x on the next approval denies directly.
park(a, "key-2", "bash", vim.json.encode({ command = "git push origin main" }), "direct-deny")
guard.touch()
local line = row_line(board, "direct-deny")
assert(line, "second approval summary not found")
vim.api.nvim_win_set_cursor(0, { line, 0 })
vim.api.nvim_feedkeys("x", "mtx", false)
assert(state.pending_approvals[a] == nil, "x did not deny the approval under the cursor")

-- Non-bash rows and board chrome leave both registers untouched.
park(a, "key-read", "read", "file.txt", "read-only")
guard.touch()
vim.fn.setreg('"', "keep unnamed")
vim.fn.setreg("+", "keep clipboard")
vim.api.nvim_feedkeys("Y", "mtx", false)
assert(vim.fn.getreg('"') == "keep unnamed" and vim.fn.getreg("+") == "keep clipboard", "Y copied a non-bash row")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("Y", "mtx", false)
assert(vim.fn.getreg('"') == "keep unnamed" and vim.fn.getreg("+") == "keep clipboard", "Y copied board chrome")
state.pending_approvals[a] = nil

-- c clears the settled history recorded this Neovim process and leaves
-- parked approvals alone: it clears the settled history view, not live
-- approvals, and no longer writes a guard.json watermark.
park(a, "key-3", "bash", "printf 'first\\nsecond'\necho done", "clear-a")
guard.record_result(a, {
  id = "settled",
  tool = "bash",
  command = "{}",
  reason = "clear-me",
}, true)
guard.touch()
vim.fn.setreg('"', "old unnamed")
vim.fn.setreg("+", "old clipboard")
vim.api.nvim_feedkeys("Y", "mtx", false)
assert(vim.fn.getreg('"') == "printf 'first\\nsecond'\necho done", "Y lost the multiline command")
assert(vim.fn.getreg("+") == vim.fn.getreg('"'), "Y lost the clipboard copy")
vim.api.nvim_feedkeys("c", "mtx", false)
assert(state.pending_approvals[a] ~= nil, "c cleared a parked approval")
local text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
assert(text:find("clear-me", 1, true) == nil, "c did not clear the settled history")
local paths = require("harness.path")
local gf = paths.session_dir(vim.fn.getcwd()) .. "/guard.json"
assert(vim.fn.filereadable(gf) == 0, "c still writes a guard.json watermark")

guard.toggle() -- close
state.running[a] = nil
print("OK guard keys")
