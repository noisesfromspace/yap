local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local frontmatter = require("harness.frontmatter")
yap.setup({ bin = ROOT .. "/tests/mock_knobs.py" })

-- Hand-edited frontmatter knobs must reach the request payload on send, the
-- same "read on every send" path the `tools` allowlist uses.
local buf = yap.new()
local e = frontmatter.end_line(buf)
local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
vim.api.nvim_buf_set_lines(
  buf,
  0,
  e,
  false,
  frontmatter.render(
    fm.provider, fm.model, fm.models, fm.created_at, fm.title, fm.description,
    fm.agent, fm.tools, fm.subagents, fm.updated_at, fm.turns, fm.created_cwd,
    fm.forked_from, fm.forks, fm.subagent_parent, "high"
  )
)
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "hi" })
yap.send()
assert(
  vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    return text:find("received-reasoning:high", 1, true) ~= nil
  end, 25),
  "frontmatter knobs did not reach the binary"
)
print("OK frontmatter knobs")
