-- Every terminal outcome should leave a sendable transcript. Drive the wire
-- frames directly so partial output, embedded errors and the graceful-vs-hard
-- stop distinction are deterministic.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local state = require("harness.state")
local document = require("harness.model.document")
local picker = require("harness.ui.picker")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })

local real_system = vim.system
local backend = nil
vim.system = function(cmd, opts, callback)
  if cmd[2] ~= "serve" then
    return real_system(cmd, opts, callback)
  end
  local p = { stdout = opts.stdout, callback = callback, cancelled = false }
  function p:write(text)
    local req = vim.json.decode(text)
    if req.type == "cancel" then
      self.cancelled = true
    end
  end
  function p:kill() end
  function p:exit(code)
    callback({ code = code or 15 })
  end
  backend = p
  return p
end
local function frame(f)
  backend.stdout(nil, vim.json.encode(f) .. "\n")
end
local buf
local function finish(f)
  frame(f)
  assert(
    vim.wait(3000, function()
      return not yap.is_running(buf)
    end, 10),
    "turn still running"
  )
end
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
local function has_msg(substr)
  for _, m in ipairs(document.messages(buf)) do
    if m.content:find(substr, 1, true) then
      return true
    end
  end
  return false
end

-- 1. Error keeps the partial + marker visible, but excludes both from the
--    next request (R-error-surface).
buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "original request" })
assert(yap.send(buf))
frame({ type = "text", text = "partial answer\n" })
finish({ type = "turn_complete", ok = false, error = { code = -32003, message = "connection reset" } })
local t = text()
assert(t:find("partial answer", 1, true), "error dropped the partial reply:\n" .. t)
assert(t:find("<!-- yap:error", 1, true), "error marker missing:\n" .. t)
assert(t:match("# @user\n$"), "error did not open a fresh prompt:\n" .. t)
assert(state.errors[buf] == "connection reset" and state.error_code[buf] == -32003)
assert(picker.state(buf) == "error", "picker did not report the failed turn")
assert(yap.winbar(buf):find(yap.config.icons.error, 1, true), "winbar missing the error icon")
assert(not has_msg("partial answer"), "failed answer leaked into the request")
assert(document.messages(buf)[#document.messages(buf)].content == "original request")

-- 2. Graceful stop keeps the partial as conversation history and opens a
--    fresh prompt.
local reused = backend
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "second request" })
assert(yap.send(buf))
assert(backend == reused, "second turn did not reuse the backend")
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
local follow_windows = document.follow_windows
local followed
-- Guard-board inspection can pause a window even at the last line. The
-- reused pipe must honor the new turn's pause, not the first turn's table.
state.running[buf].paused_follow[win] = true
document.follow_windows = function(target, wins, expected)
  if target == buf then
    followed = vim.tbl_contains(wins, win)
  end
  return follow_windows(target, wins, expected)
end
frame({ type = "text", text = "second partial\nmore output" })
assert(
  vim.wait(3000, function()
    return followed ~= nil
  end, 10),
  "second turn did not flush"
)
document.follow_windows = follow_windows
assert(not followed, "reused backend ignored this turn's paused follower")
yap.stop(buf)
assert(backend.cancelled and state.stopped[buf], "stop did not enter unwinding")
finish({ type = "turn_complete", ok = false, cancelled = true })
t = text()
assert(t:find("second partial", 1, true), "graceful stop dropped the partial:\n" .. t)
assert(t:match("# @user\n$"), "graceful stop did not open a fresh prompt:\n" .. t)
assert(state.stopped[buf] and not state.awaiting[buf] and not state.errors[buf], "cancel did not settle to stopped")
assert(picker.state(buf) == "stopped", "picker did not report the cancelled turn")
assert(yap.winbar(buf):find(yap.config.icons.stopped, 1, true), "winbar missing the stopped icon")
assert(has_msg("second partial"), "graceful stop did not keep the partial as history")

-- 3. Hard stop removes the partial and returns to the prompt that started it.
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "third request" })
assert(yap.send(buf))
frame({ type = "text", text = "third partial" })
yap.stop(buf) -- first press: graceful unwind
backend.exit(15) -- the second press kills the backend
assert(
  vim.wait(3000, function()
    return not yap.is_running(buf)
  end, 10),
  "hard stop did not finish"
)
t = text()
assert(not t:find("third partial", 1, true), "hard stop kept the partial reply:\n" .. t)
assert(t:match("third request$"), "hard stop did not restore the prompt:\n" .. t)
assert(state.stopped[buf] and not state.errors[buf], "hard stop did not settle to stopped")

-- 4. Success opens the next prompt.
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "fourth request" })
assert(yap.send(buf))
frame({ type = "text", text = "complete answer" })
finish({ type = "turn_complete", ok = true })
assert(state.awaiting[buf] and document.trailing_role(buf) == "user", "success did not open next prompt")
assert(picker.state(buf) == "waiting", "picker did not report the completed turn")
assert(yap.winbar(buf):find(yap.config.icons.waiting, 1, true), "winbar missing the waiting icon")
assert(document.messages(buf)[#document.messages(buf)].content == "complete answer")

-- 5. Embedded error keeps the marker and reports error state.
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "fifth request" })
assert(yap.send(buf))
frame({ type = "text", text = "<!-- yap:error\nempty completion\n-->\n" })
finish({ type = "turn_complete", ok = true })
t = text()
assert(t:find("<!-- yap:error", 1, true), "embedded error marker missing:\n" .. t)
assert(state.errors[buf] == "empty completion" and not state.awaiting[buf])
assert(picker.state(buf) == "error", "embedded error did not report error")

vim.system = real_system
print("OK turn outcomes")
