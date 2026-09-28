-- E2E: a running tool is visible WITHOUT streaming into the chat buffer:
-- the header lands immediately, the winbar shows the tool name, and the
-- live output stays in the tool's log file (tailed by :PitelLive), never
-- in the buffer. The result lands once, at completion. :PitelStop
-- mid-run leaves the buffer parseable (dangling tool region repaired on
-- process exit). auto_open_live opens the tail terminal by itself.
local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
pitel.setup({ bin = ROOT .. "/pitel", provider = "mock", model = "m1", auto_open_live = false })

local buf = pitel.new()
vim.api.nvim_buf_set_lines(buf, 4, -1, false, { "run the streaming command" })

-- send() goes through vim.system + schedule_wrap: poll until done.
pitel.send()

-- Mid-run: the tool header and the winbar entry are there, but NO
-- output has streamed into the buffer (the mock sleeps between l2 and
-- l3, so the turn takes ~0.5s — l1 must be absent until completion).
local mid_ok = vim.wait(10000, function()
  local t = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  return t:match("<!%-%- pitel:tool") ~= nil and pitel.winbar():match("bash") ~= nil
end, 10)
assert(mid_ok, "tool header / winbar entry not visible mid-run")
local mid_text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(not mid_text:match("\nl1\n"), "output streamed into the buffer (should stay in the log)")
assert(not mid_text:match("stream done"), "turn completed before mid-run check could run")

local done = vim.wait(30000, function()
  return vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] == ""
    and vim.api.nvim_buf_get_lines(buf, -3, -2, false)[1] == "# @user"
end, 50)
assert(done, "tool turn did not complete")

local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(text:match("<!%-%- pitel:tool"), "no tool header: " .. text)
assert(text:match("<!%-%- /pitel:tool %-%-%>"), "tool region not closed: " .. text)
assert(not text:match("pitel:stream"), "stream region leaked: " .. text)
assert(not text:match("keepstream"), "keepstream marker leaked: " .. text)
-- output landed exactly once (the header JSON names l1/l2 but never as
-- two bare consecutive lines)
assert(select(2, text:gsub("\nl1\nl2\n", "")) == 1, "output missing or duplicated: " .. text)
assert(text:match("\ntail%-without%-newline\n"), "unterminated tail missing: " .. text)
-- the marker-looking line inside the output was escaped with a visible
-- backslash, not an invisible character
assert(text:match("\n\\<!%-%- pitel:tool %-%-%>"), "marker line not backslash-escaped: " .. text)
assert(not text:match("\n<!%-%- pitel:tool %-%-%>\n"), "unescaped marker line leaked: " .. text)
assert(text:match("stream done"), "final answer missing: " .. text)
-- winbar back to idle
assert(not pitel.winbar():match("bash"), "winbar still shows the tool after completion")

-- the parsed tool message carries the result, marker line excluded
local toolmsg
for _, m in ipairs(pitel.parse_buffer(buf)) do
  if m.role == "tool" then
    toolmsg = m
  end
end
assert(toolmsg, "no tool message parsed")
assert(toolmsg.content:match("l1") and toolmsg.content:match("tail%-without%-newline"),
  "result body wrong: " .. vim.inspect(toolmsg.content))

-- Regression: a user follow-up after a tool turn must survive the
-- round-trip (a dangling tool region would swallow it on the next send).
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "follow-up after tool run" })
local msgs_rt = pitel.parse_buffer(buf)
local roles = {}
for _, m in ipairs(msgs_rt) do
  roles[#roles + 1] = m.role
end
assert(msgs_rt[#msgs_rt].role == "user" and msgs_rt[#msgs_rt].content:match("follow%-up"),
  "follow-up not parsed after tool turn; roles=" .. table.concat(roles, ","))
assert(msgs_rt[#msgs_rt - 1].role == "tool",
  "tool result lost before follow-up; roles=" .. table.concat(roles, ","))

-- ─── auto_open_live + stop mid-run ────────────────────────────────────────
pitel.config.auto_open_live = true
local buf2 = pitel.new()
vim.api.nvim_buf_set_lines(buf2, 4, -1, false, { "run again; I will stop you" })
pitel.send()

-- the live terminal opened by itself, tailing the tool's log
local term_found = vim.wait(10000, function()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buftype == "terminal" then
      return true
    end
  end
  return false
end, 20)
assert(term_found, "live terminal did not auto-open")
-- focus returned to the chat buffer
assert(vim.api.nvim_get_current_buf() == buf2, "auto-open stole focus")

pitel.stop()
-- exit callback ran (winbar idle) → repair_stream_tail already ran too
local stopped = vim.wait(5000, function()
  return not pitel.winbar():match("bash") and not pitel.winbar():match("busy")
end, 50)
assert(stopped, "stop did not settle")

local t2 = table.concat(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), "\n")
assert(t2:match("<!%-%- /pitel:tool %-%-%>"), "tool region not closed after stop: " .. t2)
local ok, msgs2 = pcall(pitel.parse_buffer, buf2)
assert(ok, "buffer unparseable after stop")
-- the tool-bearing assistant message still has its (empty) result paired
local last = msgs2[#msgs2]
assert(last.role == "tool", "dangling tool state after stop: " .. vim.inspect(last.role))
print("OK livetool")
