-- Every terminal outcome should leave a sendable transcript. Drive the wire
-- frames directly so partial output and embedded errors are deterministic.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local state = require("harness.state")
local document = require("harness.model.document")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })

local real_system = vim.system
local backend, requests = nil, {}
vim.system = function(cmd, opts, callback)
  if cmd[2] ~= "serve" then
    return real_system(cmd, opts, callback)
  end
  local p = { stdout = opts.stdout, callback = callback, cancelled = false }
  function p:write(text)
    local req = vim.json.decode(text)
    if req.type == "turn" then
      requests[#requests + 1] = req.transcript
    elseif req.type == "cancel" then
      self.cancelled = true
    end
  end
  function p:kill() end
  backend = p
  return p
end
local function frame(f)
  backend.stdout(nil, vim.json.encode(f) .. "\n")
end
local buf
local function finish(f)
  frame(f)
  assert(vim.wait(3000, function() return not yap.is_running(buf) end, 10), "turn still running")
end
buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "original request" })
assert(yap.send(buf))
frame({ type = "text", text = "partial answer\n" })
finish({ type = "turn_complete", ok = false, error = { code = -32003, message = "connection reset" } })
local transcript = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(not transcript:find("partial answer", 1, true), transcript)
assert(transcript:match("# @user\n\noriginal request$"), transcript)
assert(state.errors[buf] == "connection reset" and state.error_code[buf] == -32003)
assert(document.messages(buf)[#document.messages(buf)].content == "original request")
assert(yap.send(buf), "retry failed")
assert(not requests[2]:find("partial answer", 1, true), "failed answer leaked into retry request")
frame({ type = "text", text = "second partial" })
yap.stop(buf)
assert(backend.cancelled and state.stopped[buf], "stop did not enter unwinding")
finish({ type = "turn_complete", ok = false, cancelled = true })
transcript = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(not transcript:find("second partial", 1, true), transcript)
assert(not state.stopped[buf] and not state.awaiting[buf] and not state.errors[buf], "cancel did not settle to draft")
assert(document.messages(buf)[#document.messages(buf)].content == "original request")
assert(yap.send(buf))
frame({ type = "text", text = "complete answer" })
finish({ type = "turn_complete", ok = true })
assert(state.awaiting[buf] and document.trailing_role(buf) == "user", "success did not open next prompt")
assert(document.messages(buf)[#document.messages(buf)].content == "complete answer")
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "another request" })
assert(yap.send(buf))
frame({ type = "text", text = "<!-- yap:error\nempty completion\n-->\n" })
finish({ type = "turn_complete", ok = true })
transcript = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(not transcript:find("# @assistant\n\n<!-- yap:error", 1, true), transcript)
assert(transcript:match("# @user\n\nanother request$"), transcript)
assert(state.errors[buf] == "empty completion" and not state.awaiting[buf])
vim.system = real_system
print("OK turn outcomes")
