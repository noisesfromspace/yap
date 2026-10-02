local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

local buf = yap.new()
local chat_win = vim.api.nvim_get_current_win()

-- helper: wait for the in-flight turn to finish (mock_slow streams ~2.4s)
local function wait_turn(b)
  local ok = vim.wait(10000, function()
    local l = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    return l[#l - 1] == "# @user" and not yap.is_running(b)
  end, 100)
  assert(ok, "send did not complete")
  vim.wait(200) -- let the trailing event handlers settle
end

local function chat_text(b)
  return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
end

-- 1. normal mode: <C-s> sends the whole queue and empties it
yap.scratch_toggle()
local scratch_win = vim.api.nvim_get_current_win()
local scratch = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "task one", "task two" })
yap.scratch_send(scratch)
assert(
  table.concat(vim.api.nvim_buf_get_lines(scratch, 0, -1, false), "\n") == "",
  "normal-mode send did not clear the queue"
)
wait_turn(buf)
assert(chat_text(buf):match("task one") and chat_text(buf):match("task two"), "queued tasks missing from chat")

-- 2. visual line-wise: only the selected lines leave the queue
vim.api.nvim_set_current_win(scratch_win)
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "line alpha", "line beta", "line gamma" })
vim.api.nvim_win_set_cursor(scratch_win, { 1, 0 })
vim.cmd("normal! V")
vim.api.nvim_win_set_cursor(scratch_win, { 2, 0 })
assert(vim.api.nvim_get_mode().mode == "V", "expected line-wise visual, got " .. vim.api.nvim_get_mode().mode)
yap.scratch_send(scratch)
assert(
  table.concat(vim.api.nvim_buf_get_lines(scratch, 0, -1, false), "\n") == "line gamma",
  "visual send removed the wrong lines: " .. vim.inspect(vim.api.nvim_buf_get_lines(scratch, 0, -1, false))
)
wait_turn(buf)
assert(chat_text(buf):match("line alpha") and chat_text(buf):match("line beta"), "visual selection missing from chat")

-- 3. visual char-wise: exactly the selected characters leave the queue
vim.api.nvim_set_current_win(scratch_win)
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "abcdef", "ghijkl" })
vim.api.nvim_win_set_cursor(scratch_win, { 1, 2 })
vim.cmd("normal! v")
vim.api.nvim_win_set_cursor(scratch_win, { 2, 3 })
assert(vim.api.nvim_get_mode().mode == "v", "expected char-wise visual, got " .. vim.api.nvim_get_mode().mode)
yap.scratch_send(scratch)
assert(
  table.concat(vim.api.nvim_buf_get_lines(scratch, 0, -1, false), "\n") == "ab\nkl",
  "char-wise send removed the wrong text: " .. vim.inspect(vim.api.nvim_buf_get_lines(scratch, 0, -1, false))
)
wait_turn(buf)
assert(chat_text(buf):match("cdef"), "char-wise selection missing from chat")
assert(chat_text(buf):match("ghij"), "char-wise selection missing from chat")

print("OK scratch_send")
