-- Direct row keys on the guard board: r/x run/deny the approval under the
-- cursor without opening the transient, and i is bound for every row.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local state = require("harness.state")
local guard = require("harness.guard")

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
assert(vim.api.nvim_buf_get_name(board) == "yap://guard", "guard board did not open")

for _, key in ipairs({ "r", "x", "i" }) do
  local m = vim.fn.maparg(key, "n", false, true)
  assert(m and m.buffer == 1, "guard board missing direct '" .. key .. "' keymap")
end

-- r on the cursor row (already the first Open row) approves directly.
vim.api.nvim_feedkeys("r", "mtx", false)
assert(state.pending_approvals[a] == nil, "r did not approve the approval under the cursor")

-- x on the next approval denies directly.
park(a, "key-2", "ssh", "ssh root@db restart nginx", "direct-deny")
guard.touch()
local line = row_line(board, "direct-deny")
assert(line, "second approval summary not found")
vim.api.nvim_win_set_cursor(0, { line, 0 })
vim.api.nvim_feedkeys("x", "mtx", false)
assert(state.pending_approvals[a] == nil, "x did not deny the approval under the cursor")

guard.toggle() -- close
state.running[a] = nil
print("OK guard keys")
