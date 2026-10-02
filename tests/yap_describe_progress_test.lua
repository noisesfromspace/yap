local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({
  bin = ROOT .. "/yap",
  description_model = "mock/m1",
  description_answer_model = "mock/m1",
})

local log_path = "/tmp/yap-describe-progress.log"
os.remove(log_path)

local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "List /tmp please" })
yap.send()

-- The mock streams a tool call, then a delayed final answer.
local ok = vim.wait(15000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):match("directory listing is shown above") ~= nil
end, 100)
assert(ok, "turn did not complete")

local function read_log()
  local f = io.open(log_path, "r")
  if not f then
    return ""
  end
  local text = f:read("*a")
  f:close()
  return text
end

-- All three stages fire: user on send, progress mid-turn, answer on the
-- completed turn.
ok = vim.wait(10000, function()
  local text = read_log()
  return text:match("user's request")
    and text:match("currently working on")
    and text:match("centered on the overall goal")
end, 100)
assert(ok, "description requests missing from log: " .. read_log())

local progress
for l in read_log():gmatch("[^\n]+") do
  if l:match("currently working on") then
    progress = l
  end
end

-- The in-turn summary is fed the recent tool call, not the final answer.
assert(progress and progress:match("Tool call: ls"), "progress request missing tool call: " .. tostring(progress))
assert(not progress:match("directory listing is shown above"), "progress request leaked the final answer: " .. progress)

-- Wait for the asynchronous description callback to write the frontmatter.
ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, 8, false), "\n"):match("description: described%.") ~= nil
end, 50)
assert(ok, "description not written to frontmatter")

print("OK describe-progress")
