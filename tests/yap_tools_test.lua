local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local frontmatter = require("harness.frontmatter")
yap.setup({ bin = ROOT .. "/tests/mock_tools.py" })

-- 1. a normal session's frontmatter lists every tool the binary reports
local buf = yap.new()
local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
assert(
  fm.tools and vim.deep_equal(fm.tools, { "bash", "ls", "read" }),
  "normal session should list all tools: " .. vim.inspect(fm and fm.tools)
)

-- 2. removing a tool from the list retracts it on the next send
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local kept = {}
for _, l in ipairs(lines) do
  if l ~= "  - bash" then
    kept[#kept + 1] = l
  end
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, kept)
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "hi" })
yap.send()
assert(
  vim.wait(2000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    return text:find("received-tools:ls,read", 1, true) ~= nil
  end, 20),
  "edited allowlist did not reach the binary"
)

print("OK tools allowlist")
