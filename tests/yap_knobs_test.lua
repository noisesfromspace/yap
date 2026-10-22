local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local frontmatter = require("harness.model.frontmatter")
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
  frontmatter.render({
    provider = fm.provider,
    model = fm.model,
    models = fm.models,
    created_at = fm.created_at,
    title = fm.title,
    description = fm.description,
    agent = fm.agent,
    tools = fm.tools,
    subagents = fm.subagents,
    updated_at = fm.updated_at,
    turns = fm.turns,
    created_cwd = fm.created_cwd,
    forked_from = fm.forked_from,
    forks = fm.forks,
    subagent_parent = fm.subagent_parent,
    reasoning_level = "high",
  })
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
