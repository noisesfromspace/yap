local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local frontmatter = require("harness.model.frontmatter")
yap.setup({ bin = ROOT .. "/tests/mock_tools.py" })

-- 1. a normal session is unrestricted: no `tools:` frontmatter block, so the
-- built-in tools and any runtime-discovered MCP tools are all available.
local buf = yap.new()
local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
assert(fm.tools == nil, "normal session should be unrestricted: " .. vim.inspect(fm and fm.tools))

-- 2. an explicit allowlist (as a subagent passes) is written and sent as-is.
local buf2 = yap.new({ tools = { "ls", "read" } })
local fm2 = frontmatter.parse(vim.api.nvim_buf_get_lines(buf2, 0, -1, false))
assert(
  fm2.tools and vim.deep_equal(fm2.tools, { "ls", "read" }),
  "explicit allowlist not written: " .. vim.inspect(fm2 and fm2.tools)
)
vim.api.nvim_buf_set_lines(buf2, -1, -1, false, { "hi" })
yap.send()
assert(
  vim.wait(2000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), "\n")
    return text:find("received-tools:ls,read", 1, true) ~= nil
  end, 20),
  "explicit allowlist did not reach the binary"
)

print("OK tools allowlist")
