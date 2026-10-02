local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({
  bin = ROOT .. "/yap",
  description_model = "mock/m1",
  description_answer_model = "mock/m1",
})

local log_path = "/tmp/yap-describe.log"
os.remove(log_path)

local buf = yap.new({ provider = "mock", model = "m1" })
-- Replace the trailing empty line with the user message.
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "Fix the session picker label" })
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

-- The tiny send-time summary and the bigger answer-time summary both hit
-- the mock; wait until both prompts have been logged.
ok = vim.wait(10000, function()
  local text = read_log()
  return text:match("user's request") and text:match("centered on the overall goal")
end, 100)
assert(ok, "description requests missing from log: " .. read_log())

local tiny, full
for l in read_log():gmatch("[^\n]+") do
  if l:match("user's request") then
    tiny = l
  end
  if l:match("centered on the overall goal") then
    full = l
  end
end

-- Tiny model: only the latest user message, no assistant answer.
assert(tiny and tiny:match("Fix the session picker label"), "tiny request missing user message: " .. tostring(tiny))
assert(not tiny:match("described%."), "tiny request leaked the assistant answer: " .. tiny)
-- Bigger model: whole session, user message plus the assistant answer.
assert(full and full:match("Fix the session picker label"), "answer request missing user message: " .. tostring(full))
assert(full:match("described%."), "answer request missing assistant answer: " .. full)

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

print("OK describe")
