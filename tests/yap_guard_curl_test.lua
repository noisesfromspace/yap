-- A parked curl approval must show the flags/method/body that triggered the
-- gate, not just the target URL: the bare URL hides the very thing the human
-- is being asked to decide on (a file I/O flag, a non-GET method, a body).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local state = require("harness.state")
local guard = require("harness.ui.guard")

local a = yap.new({ provider = "mock", model = "m1" })

local function park(command, reason)
  state.running[a] = {}
  state.pending_approvals[a] = {
    id = "curl-" .. math.random(1000, 9999),
    tool = "curl",
    command = command,
    reason = reason,
    ts = os.date("%Y-%m-%dT%H:%M:%S"),
  }
  guard.toggle()
  local board = vim.api.nvim_get_current_buf()
  local text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
  guard.toggle() -- close
  state.pending_approvals[a] = nil
  return text
end

-- A file I/O flag must be visible: the flag is the thing being gated.
local t1 = park(vim.json.encode({ url = "https://example.com/", flags = "--output /tmp/x" }), "reads or writes a local file")
assert(t1:find("--output /tmp/x", 1, true), "curl flags not shown: " .. t1)
assert(t1:find("https://example.com/", 1, true), "curl URL not shown: " .. t1)

-- A non-GET method must be visible alongside the URL.
local t2 = park(vim.json.encode({ url = "https://example.com/", method = "POST" }), "non-GET request method")
assert(t2:find("-X POST", 1, true), "curl method not shown: " .. t2)

-- A request body must be visible: it is the data leaving the machine.
local t3 = park(vim.json.encode({ url = "https://example.com/", data = "secret-ish body" }), "sends a request body")
assert(t3:find("secret-ish body", 1, true), "curl body not shown: " .. t3)

state.running[a] = nil
print("OK guard curl")
