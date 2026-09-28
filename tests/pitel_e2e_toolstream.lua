-- E2E: live tool output streams into the buffer while the tool runs
-- (pitel:stream region), the truncated result lands as the region body
-- (pitel:stream excluded on re-send), and :PitelStop mid-stream leaves
-- the buffer parseable (dangling regions repaired on process exit).
local pitel = require("harness")
pitel.setup({ bin = vim.env.PITEL_ROOT .. "/pitel", provider = "mock", model = "m1" })

local buf = pitel.new()
vim.api.nvim_buf_set_lines(buf, 4, -1, false, { "run the streaming command" })

-- send() goes through vim.system + schedule_wrap: poll until done.
pitel.send()

-- Mid-run visibility: the mock command sleeps 0.4s between l2 and l3,
-- so l1 must be in the buffer BEFORE the turn completes.
local mid_ok = vim.wait(10000, function()
  local t = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  return t:match("l1") ~= nil and not t:match("stream done")
end, 20)
assert(mid_ok, "live output was not visible mid-run (only appeared at completion)")

local done = vim.wait(30000, function()
  return vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] == ""
    and vim.api.nvim_buf_get_lines(buf, -3, -2, false)[1] == "# @user"
end, 50)
assert(done, "streaming tool turn did not complete")

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local text = table.concat(lines, "\n")

-- tool header visible with the call, stream region present with output
assert(text:match("<!%-%- pitel:tool %{.*\"name\":\"bash\""), "no tool header: " .. text)
assert(text:match("<!%-%- pitel:stream\n"), "no stream region: " .. text)
assert(text:match("l1\n"), "stream output missing: " .. text)
assert(text:match("l3\n"), "late stream output missing: " .. text)
assert(text:match("tail%-without%-newline"), "unterminated tail missing: " .. text)
assert(text:match("<!%-%- /pitel:tool %-%-%>"), "tool region not closed: " .. text)
-- result body is the full short output (not truncated), stream excluded
local msgs = pitel.parse_buffer(buf)
local toolmsg
for _, m in ipairs(msgs) do
  if m.role == "tool" then
    toolmsg = m
  end
end
assert(toolmsg, "no tool message parsed")
assert(toolmsg.content:match("l1") and toolmsg.content:match("tail%-without%-newline"),
  "result body wrong: " .. vim.inspect(toolmsg.content))
assert(not toolmsg.content:match("l3.*l3"), "stream duplicated into result?")
-- the model's marker-looking line inside output was escaped
assert(not toolmsg.content:match("^<!%-%- pitel:tool %-%-%>"), "marker leaked into result")

-- streamed text lands mid-buffer; final prose after the region
assert(text:match("stream done"), "final answer missing: " .. text)

-- ─── stop mid-stream: buffer must stay parseable ──────────────────────────
local buf2 = pitel.new()
vim.api.nvim_buf_set_lines(buf2, 4, -1, false, { "run again; I will stop you" })
pitel.send()
-- wait until live output has actually started arriving
local streaming = vim.wait(10000, function()
  local t = table.concat(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), "\n")
  return t:match("<!%-%- pitel:stream") ~= nil and t:match("l1") ~= nil
end, 50)
assert(streaming, "stream never started")
vim.api.nvim_set_current_buf(buf2)
pitel.stop()
-- give the exit callback a tick to run repair_stream_tail
vim.wait(5000, function()
  return not require("harness").winbar():match("busy")
end, 50)
vim.wait(200, function() return false end, 50) -- let scheduled callbacks land

local t2 = table.concat(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), "\n")
assert(t2:match("%-%->"), "stream region not closed after stop: " .. t2)
assert(t2:match("<!%-%- /pitel:tool %-%-%>"), "tool region not closed after stop: " .. t2)
local ok, msgs2 = pcall(pitel.parse_buffer, buf2)
assert(ok, "buffer unparseable after stop")
-- every tool-bearing assistant message has its results; region is closed
local last = msgs2[#msgs2]
assert(last.role == "user" or last.role == "tool",
  "dangling tool state after stop: " .. vim.inspect(last.role))
