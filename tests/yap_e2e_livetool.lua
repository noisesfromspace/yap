-- E2E: a running tool is visible WITHOUT streaming into the session buffer:
-- the header lands immediately, the winbar shows the tool name, and the
-- live output stays in the tool's log file (rendered by live()), never
-- in the buffer. The result lands once, at completion. stop()
-- mid-run leaves the buffer parseable (dangling tool region repaired on
-- process exit). auto_open_live opens the tail viewer by itself.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local state = require("harness.state")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

-- The persistent tail viewer buffer of a session buffer (yap://<name>-tail).
local function tail_buf(chat)
  local name = vim.api.nvim_buf_get_name(chat)
  name = name:match("^yap://") and (name .. "-tail")
    or ("yap://" .. require("harness.path").session_name(name) .. "-tail")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
end

-- Replace the typing line under the LAST # @user heading (a positional
-- set_lines would delete the heading itself).
local function set_prompt(b, text)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i] == "# @user" then
      vim.api.nvim_buf_set_lines(b, i, -1, false, { text })
      return
    end
  end
end

local buf = yap.new()
set_prompt(buf, "run the streaming command")

-- send() goes through vim.system + schedule_wrap: poll until done.
yap.send()

-- Mid-run: the tool header lands immediately; the winbar shows only the
-- spinner until the tool has run 2s, then its name joins it. No output
-- has streamed into the buffer (the mock sleeps ~2.2s between l2 and l3,
-- so l1 must be absent until completion).
local header_ok = vim.wait(10000, function()
  local t = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  return t:match("<!%-%- yap:tool") ~= nil
end, 10)
assert(header_ok, "tool header not visible mid-run")
assert(not yap.winbar():match("bash"), "winbar shows the tool name before 2s: " .. yap.winbar())
local sparkle_frames = require("harness.ui.spinner").spinner_frames
local has_colored_icon = false
for _, frame in ipairs(sparkle_frames) do
  local bar = yap.winbar()
  if bar:find(frame, 1, true) and bar:find("%#YapBusySpin#", 1, true) then
    has_colored_icon = true
    break
  end
end
assert(has_colored_icon, "winbar is missing the spinner color: " .. yap.winbar())
local spin_hl = vim.api.nvim_get_hl(0, { name = "YapBusySpin", link = false })
assert(type(spin_hl.fg) == "number" and spin_hl.fg >= 0, "YapBusySpin should carry a 24-bit spinner color")
local text_hl = vim.api.nvim_get_hl(0, { name = "YapBusyText", link = false })
assert(text_hl.italic, "activity text should stay italic")
assert(text_hl.fg == spin_hl.fg, "activity text should tint with the beacon color")
local mid_ok = vim.wait(10000, function()
  local bar = yap.winbar()
  return bar:find("bash", 1, true) ~= nil and bar:find("%#YapBusyText#", 1, true) ~= nil
end, 10)
assert(mid_ok, "winbar did not show readable, separately highlighted tool text after 2s: " .. yap.winbar())
local mid_text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(not mid_text:match("\nl1\n"), "output streamed into the buffer (should stay in the log)")
assert(not mid_text:match("stream done"), "turn completed before mid-run check could run")

-- the tail view buffer IS filling while the tool runs
local tb1
local tail_filling = vim.wait(10000, function()
  tb1 = tail_buf(buf)
  return tb1 and table.concat(vim.api.nvim_buf_get_lines(tb1, 0, -1, false), "\n"):match("\nl1\n") ~= nil
end, 20)
assert(tail_filling, "tail viewer buffer not filling during the run")

local done = vim.wait(30000, function()
  return vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] == ""
    and vim.api.nvim_buf_get_lines(buf, -3, -2, false)[1] == "# @user"
end, 50)
assert(done, "tool turn did not complete")

local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(text:match("<!%-%- yap:tool"), "no tool header: " .. text)
assert(text:match("<!%-%- /yap:tool %-%-%>"), "tool region not closed: " .. text)
assert(not text:match("yap:stream"), "stream region leaked: " .. text)
assert(not text:match("keepstream"), "keepstream marker leaked: " .. text)
-- output landed exactly once (the header JSON names l1/l2 but never as
-- two bare consecutive lines)
assert(select(2, text:gsub("\nl1\nl2\n", "")) == 1, "output missing or duplicated: " .. text)
assert(text:match("\ntail%-without%-newline\n"), "unterminated tail missing: " .. text)
-- the marker-looking line inside the output was escaped with a visible
-- backslash, not an invisible character
assert(text:match("\n\\<!%-%- yap:tool %-%-%>"), "marker line not backslash-escaped: " .. text)
assert(not text:match("\n<!%-%- yap:tool %-%-%>\n"), "unescaped marker line leaked: " .. text)
assert(text:match("stream done"), "final answer missing: " .. text)
local tool_start, tool_end, resumed =
  text:find("<!-- yap:tool", 1, true), text:find("<!-- /yap:tool -->", 1, true), text:find("stream done", 1, true)
assert(
  tool_start and tool_end and resumed and tool_start < tool_end and tool_end < resumed,
  "buffer order must be tool call -> result -> resumed assistant text: " .. text
)
-- winbar back to idle
assert(not yap.winbar():match("bash"), "winbar still shows the tool after completion")

-- the tail view holds the FULL output (tool_end drains before the temp log
-- of an untruncated run is deleted), with the command as a `$` header
local tail_text = table.concat(vim.api.nvim_buf_get_lines(tb1, 0, -1, false), "\n")
assert(tail_text:match("%$ printf"), "no command header in the tail view: " .. tail_text)
assert(
  tail_text:match("\nl1\nl2\n") and tail_text:match("tail%-without%-newline"),
  "tail view incomplete: " .. tail_text
)

-- the parsed assistant message carries the flattened result, marker line excluded
local asst
for _, m in ipairs(yap.parse_buffer(buf)) do
  if m.role == "assistant" then
    asst = m
  end
end
assert(asst, "no assistant message parsed")
assert(
  asst.content:match("l1") and asst.content:match("tail%-without%-newline"),
  "result body wrong: " .. vim.inspect(asst.content)
)

-- Regression: a user follow-up after a tool turn must survive the
-- round-trip (a dangling tool region would swallow it on the next send).
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "follow-up after tool run" })
local msgs_rt = yap.parse_buffer(buf)
local roles = {}
for _, m in ipairs(msgs_rt) do
  roles[#roles + 1] = m.role
end
assert(
  msgs_rt[#msgs_rt].role == "user" and msgs_rt[#msgs_rt].content:match("follow%-up"),
  "follow-up not parsed after tool turn; roles=" .. table.concat(roles, ",")
)
assert(
  msgs_rt[#msgs_rt - 1].role == "assistant",
  "flattened assistant lost before follow-up; roles=" .. table.concat(roles, ",")
)

-- ─── live() + stop mid-run ───────────────────────────────────────────
local buf2 = yap.new()
set_prompt(buf2, "run again; I will stop you")
yap.send()

-- wait until the tool header has landed, then live() opens the
-- (already created) tail viewer in a split, scrolled to the bottom
local started = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), "\n"):match("<!%-%- yap:tool") ~= nil
end, 20)
assert(started, "tool header not present before stop")
local tb2 = tail_buf(buf2)
assert(tb2, "no tail viewer buffer for the second session")
yap.live()
assert(
  vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):match("%-tail$"),
  "live() did not open the tail viewer"
)
assert(vim.api.nvim_win_get_cursor(0)[1] == vim.api.nvim_buf_line_count(0), "tail viewer window not at the bottom")

-- The tail viewer is a winfixbuf drawer; switching its buffer would raise
-- E1513. Return focus to the session window, where stop() acts.
vim.api.nvim_set_current_win(vim.fn.win_findbuf(buf2)[1])
vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- park away from the stream tail
local stop_row = vim.api.nvim_win_get_cursor(0)[1]
yap.stop()
assert(state.stopped[buf2], "manual stop state not recorded")
assert(
  vim.api.nvim_win_get_cursor(0)[1] == stop_row,
  "stop moved the cursor away from where it was parked"
)
-- M.stop() closes the stream immediately; the process exit callback may lag behind.
local repaired = vim.wait(5000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), "\n"):match("<!%-%- /yap:tool %-%-%>") ~= nil
end, 20)
assert(repaired, "tool region not closed after stop")

local stopped_lines = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
assert(
  stopped_lines[#stopped_lines - 1] == "# @user" and stopped_lines[#stopped_lines] == "",
  "stopped stream did not end in a closed user block"
)
local t2 = table.concat(stopped_lines, "\n")
local ok, msgs2 = pcall(yap.parse_buffer, buf2)
assert(ok, "buffer unparseable after stop")
-- the tool-bearing assistant message still has its (empty) result flattened
local last = msgs2[#msgs2]
assert(last.role == "assistant", "dangling tool state after stop: " .. vim.inspect(last.role))
print("OK livetool")
