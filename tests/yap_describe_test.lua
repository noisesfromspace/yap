local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({
  bin = ROOT .. "/yap",
  description_model = "",
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
  return read_log():match("centered on the overall goal") ~= nil
end, 100)
assert(ok, "description requests missing from log: " .. read_log())

local full
for l in read_log():gmatch("[^\n]+") do
  if l:match("centered on the overall goal") then
    full = l
  end
end

-- The answer title sees the task and assistant work, but not the routine footer.
assert(full and full:match("Fix the session picker label"), "answer request missing substantive task: " .. tostring(full))
assert(full:match("described%.") and full:match("Implemented the picker label fix"), "answer request missing session work: " .. full)
assert(not full:match("Commit changes from this session"), "routine commit footer leaked into title input: " .. full)
assert(full:match("Routine commit/close instructions are housekeeping"), "answer title prompt lacks housekeeping guidance: " .. full)

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

-- A later routine commit/close turn must keep that useful title rather than
-- requesting a replacement from either description stage.
local title_requests = 0
for l in read_log():gmatch("[^\n]+") do
  if l:match("centered on the overall goal") then
    title_requests = title_requests + 1
  end
end
vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
  "Commit changes from this session and close.",
})
yap.send()
ok = vim.wait(10000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local answers = 0
  for _ in text:gmatch("described%.") do
    answers = answers + 1
  end
  return answers >= 3
end, 100)
assert(ok, "follow-up housekeeping turn did not complete")
local after_title_requests = 0
for l in read_log():gmatch("[^\n]+") do
  if l:match("centered on the overall goal") then
    after_title_requests = after_title_requests + 1
  end
end
assert(after_title_requests == title_requests, "housekeeping turn generated a replacement title")
local after_lines = vim.api.nvim_buf_get_lines(buf, 0, 8, false)
assert(table.concat(after_lines, "\n"):match("description: described%."), "housekeeping turn changed the existing title")

-- Keep the send-time title stage covered: it should summarize only the new
-- request, not prior assistant output from another turn.
yap.config.description_model = "mock/m1"
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

print("OK describe")
