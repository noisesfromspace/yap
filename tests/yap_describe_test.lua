local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
package.loaded.harness = nil -- start-packages may have loaded the installed copy before this test prepended the repo
local yap = require("harness")
yap.setup({
  bin = ROOT .. "/yap",
  description_model = "mock/m1",
  description_answer_model = "mock/m1",
})

local log_path = "/tmp/yap-describe.log"
os.remove(log_path)

local buf = yap.new({ provider = "mock", model = "m1" })
-- Reproduce the common title failure: a substantive task followed by the
-- routine end-of-session commit instruction.
vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
  "Fix the session picker label",
  "# @assistant",
  "Implemented the picker label fix.",
  "# @user",
  "Commit changes from this session and ignore unrelated changes, potentially another AI session made those. If this completes the requests of the user use the close tool to close the session",
})
yap.send()

local ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):match("described%.") ~= nil
end, 100)
assert(ok, "send did not complete")

local function read_log()
  local f = io.open(log_path, "r")
  if not f then
    return ""
  end
  local text = f:read("*a")
  f:close()
  return text
end

-- Wait until the completion-title request has been logged.
ok = vim.wait(10000, function()
  local text = read_log()
  return text:match("user's request") and text:match("centered on the overall work")
end, 100)
assert(ok, "description requests missing from log: " .. read_log())

local tiny, full
for line in read_log():gmatch("[^\n]+") do
  local ok, messages = pcall(vim.json.decode, line)
  if ok and type(messages) == "table" then
    local system = messages[1] and messages[1].content or ""
    if system:match("Write a short title for the user's request") then
      tiny = line
    elseif system:match("centered on the overall work") then
      full = line
    end
  end
end

assert(tiny and tiny:match("Fix the session picker label"), "instant title missing initial request: " .. tostring(tiny))
assert(not tiny:match("Commit changes from this session"), "instant title used the commit footer: " .. tiny)

-- The answer title sees the task requests, but excludes assistant transcript/tool output.
assert(full and full:match("Fix the session picker label"), "overall title missing initial request: " .. tostring(full))
assert(not full:match("described%.") and not full:match("Implemented the picker label fix"),
  "assistant content leaked into title input: " .. full)
assert(not full:match("Commit changes from this session"), "routine commit footer leaked into title input: " .. full)
assert(full:match("first request anchors the session's main goal"), "overall title prompt does not anchor the first request: " .. full)

-- The requests are logged before their replies complete. Wait for the
-- asynchronous description callback to update the frontmatter.
ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, 8, false), "\n"):match("description: described%.") ~= nil
end, 50)
local lines = vim.api.nvim_buf_get_lines(buf, 0, 8, false)
assert(ok and
  table.concat(lines, "\n"):match("description: described%."),
  "description not written to frontmatter: " .. table.concat(lines, "\n")
)

-- A new session still gets an instant label from its first query.
local tiny_buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(tiny_buf, -1, -1, false, { "Add a searchable session filter" })
yap.send(tiny_buf)
ok = vim.wait(10000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(tiny_buf, 0, -1, false), "\n")
  local answers = 0
  for _ in text:gmatch("described%.") do
    answers = answers + 1
  end
  return answers >= 2
end, 100)
assert(ok, "send-time title test turn did not complete")
local tiny
for l in read_log():gmatch("[^\n]+") do
  if l:match("user's request") then
    tiny = l
  end
end
assert(tiny and tiny:match("Add a searchable session filter"), "tiny request missing new user request: " .. tostring(tiny))
assert(not tiny:match("described%.") and not tiny:match("Fix the session picker label"), "tiny request included previous conversation: " .. tiny)

-- A title request never sees assistant tool output, and a fenced model reply
-- is rejected rather than persisted as the session description.
local fence_buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(fence_buf, -1, -1, false, {
  "Fence regression trigger: improve the session title",
  "# @assistant",
  "Tool call: git",
  "Arguments: {\"command\":\"status\"}",
  "Tool result:",
  "```",
  "## main...rad/main [ahead 3]",
  "M lua/harness/init.lua",
  "```",
  "# @user",
  "Continue the title fix",
})
yap.send(fence_buf)
ok = vim.wait(10000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(fence_buf, 0, -1, false), "\n")
  return text:find("described%.") ~= nil
end, 100)
assert(ok, "fence-regression turn did not complete")
ok = vim.wait(10000, function()
  for line in read_log():gmatch("[^\n]+") do
    if line:match("centered on the overall work") and line:match("Fence regression trigger") then
      return true
    end
  end
  return false
end, 100)
assert(ok, "fence-regression title request was not logged")
local fence_request
for line in read_log():gmatch("[^\n]+") do
  if line:match("centered on the overall work") and line:match("Fence regression trigger") then
    fence_request = line
  end
end
assert(fence_request and not fence_request:match("git status") and not fence_request:match("ahead 3"),
  "assistant tool output leaked into title context: " .. tostring(fence_request))
local fence_lines = vim.api.nvim_buf_get_lines(fence_buf, 0, 8, false)
assert(not table.concat(fence_lines, "\n"):match("description:.*```"), "fenced title was persisted")

print("OK describe")
