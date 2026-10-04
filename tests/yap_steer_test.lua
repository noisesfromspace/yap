local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

local buf = yap.new()
local chat_win = vim.api.nvim_get_current_win()

local function chat_text(b)
  return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
end

-- Start a turn that calls a slow tool (mock_steer: sleep 1.5).
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "do some work" })
yap.send(buf)
local ok = vim.wait(10000, function()
  return yap.is_running(buf)
end, 50)
assert(ok, "turn did not start")
-- Give the serve backend time to set up its steer channel and start the
-- tool (microseconds) — the tool itself sleeps 1.5s, so this lands mid-turn.
vim.wait(400)

-- Open the scratch, put a steering note in it, and steer while running.
yap.scratch_toggle()
local scratch = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "also check the tests" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
yap.scratch_send(scratch)

-- Steering must NOT drain the scratch: the draft stays in place.
assert(
  table.concat(vim.api.nvim_buf_get_lines(scratch, 0, -1, false), "\n") == "also check the tests",
  "steer drained the scratch"
)

-- The turn completes with the steer injected mid-turn.
local ok2 = vim.wait(15000, function()
  local l = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return l[#l - 1] == "# @user" and not yap.is_running(buf)
end, 100)
assert(ok2, "turn did not complete after steer")
vim.wait(200)

local t = chat_text(buf)
assert(t:match("# @user\nalso check the tests"), "steer block missing from chat:\n" .. t)
assert(t:match("final answer"), "final answer missing from chat:\n" .. t)
assert(not t:match("STEER MISSING"), "steer did not reach the model:\n" .. t)
-- The steer block must precede the final answer: it landed at the tool
-- boundary, not as a trailing follow-up.
local steer_at = t:find("# @user\nalso check the tests", 1, true)
local answer_at = t:find("final answer", 1, true)
assert(steer_at and answer_at and steer_at < answer_at, "steer landed after the final answer:\n" .. t)

print("OK steer")
