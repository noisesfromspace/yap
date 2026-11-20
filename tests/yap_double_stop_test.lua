-- The first stop lets a tool finish; the second kills the backend and its
-- tool process group without waiting for the tool's sleep.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = vim.env.YAP_TEST_BIN or ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })
local state = require("harness.state")

local function start(prompt)
  local buf = yap.new({ provider = "mock", model = "m1" })
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { prompt })
  assert(yap.send(buf))
  assert(
    vim.wait(5000, function()
      return state.live[buf] and state.live[buf].name == "bash"
    end, 10),
    "bash never started"
  )
  local stop_map
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.desc == "yap: stop in-flight request" then
      stop_map = map.callback
    end
  end
  assert(stop_map)
  return buf, stop_map
end

local buf, stop = start("graceful")
local process = state.servers[buf]
stop()
assert(state.servers[buf] == process and yap.is_running(buf), "first stop killed the backend")
local bar = yap.winbar(buf)
local adjacent = "%#YapNeeds#" .. yap.config.icons.stopped .. "%*%#YapBusySpin#"
assert(bar:find(adjacent, 1, true), "stop icon is not beside the spinner")
vim.wait(200)
assert(yap.is_running(buf), "first stop cancelled the running tool")
assert(
  vim.wait(5000, function()
    return not yap.is_running(buf)
  end, 10),
  "tool did not finish"
)
local transcript = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(transcript:find("1\n2\n3\nfinished", 1, true), "first stop did not preserve the full counting tool result")
assert(not transcript:find("unexpected next model step", 1, true), "continued to another model step")
local stop_marker = assert(transcript:match("<!%-%- yap:event (.-) %-%->"), "graceful stop left no marker")
local stop_event = vim.json.decode(stop_marker)
assert(stop_event.type == "turn_stopped" and stop_event.outcome == "stopped", "wrong graceful marker: " .. stop_marker)
assert(state.servers[buf] == process and state.stopped[buf], "graceful stop lost backend or status")
vim.cmd("stopinsert")

local hard, hard_stop = start("hard")
hard_stop()
assert(yap.is_running(hard), "first press did not leave the tool running")
hard_stop()
assert(
  vim.wait(1500, function()
    return not yap.is_running(hard)
  end, 10),
  "second stop waited for bash"
)
assert(not state.servers[hard] and not state.errors[hard], "hard stop left backend or error")
local hard_transcript = table.concat(vim.api.nvim_buf_get_lines(hard, 0, -1, false), "\n")
assert(not hard_transcript:find("\n10\ntoo-late", 1, true), "hard stop let the counting tool complete")
local hard_marker = assert(hard_transcript:match("<!%-%- yap:event (.-) %-%->"), "hard stop left no marker")
local hard_event = vim.json.decode(hard_marker)
assert(hard_event.type == "turn_stopped" and hard_event.outcome == "killed", "wrong hard marker: " .. hard_marker)
assert(require("harness.model.document").trailing_role(hard) == "user", "no writable prompt")
assert(not yap.winbar(hard):find("YapBusySpin", 1, true), "stopping spinner lingered")
vim.cmd("stopinsert")
vim.api.nvim_buf_set_lines(hard, -1, -1, false, { "restart" })
assert(yap.send(hard), "could not restart backend")
assert(
  vim.wait(5000, function()
    return not yap.is_running(hard)
  end, 10),
  "restart did not complete"
)
assert(state.servers[hard] ~= process, "reused dead backend")
print("OK graceful and hard Ctrl-C")
