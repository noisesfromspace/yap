-- Parser/fold badge coverage for the session events beyond guard decisions:
-- a cost override and a stop marker badge their assistant fold; a fork badges
-- the frontmatter fold. Pure state, no provider traffic.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local fold = require("harness.ui.fold")
local structure = require("harness.model.structure")

local function heading(scan, role)
  for _, h in ipairs(scan.headings) do
    if h.role == role then
      return h.line
    end
  end
  return nil
end

-- A reply that cost more than the guard allowed and then was stopped.
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "---",
  "description: no fork",
  "---",
  "",
  "# @system",
  "",
  "helpful",
  "",
  "# @user",
  "",
  "go",
  "",
  '<!-- yap:event {"type":"cost_override","combo":"mock/m1","estimate_usd":1.25,"ts":"2025-09-29T19:22:33Z"} -->',
  "",
  "# @assistant",
  "",
  "reply",
  "",
  '<!-- yap:event {"type":"turn_stopped","outcome":"stopped","ts":"2025-09-29T19:22:33Z"} -->',
  "",
})

local p = structure.parse(buf)
local assistant = assert(heading(p, "assistant"), "no assistant heading")
local finish = vim.api.nvim_buf_line_count(buf)

assert(#p.events == 2, "events: " .. #p.events)
local cost, stop = p.events[1], p.events[2]
assert(cost.kind == "cost_override" and cost.assistant == assistant, "cost: " .. vim.inspect(cost))
assert(
  stop.kind == "turn_stopped" and stop.outcome == "stopped" and stop.assistant == assistant,
  "stop: " .. vim.inspect(stop)
)

-- The assistant fold badges the cost override (warning) and the stop (warning).
local chunks = fold.text(assistant, finish)
assert(type(chunks) == "table", "assistant fold returned no badges")
assert(chunks[1][1] == "[Cost override] " and chunks[1][2] == "DiagnosticWarn", vim.inspect(chunks[1]))
assert(chunks[2][1] == "[Stopped] " and chunks[2][2] == "DiagnosticWarn", vim.inspect(chunks[2]))
assert(chunks[3][1]:find("▸ @assistant", 1, true), vim.inspect(chunks[3]))

-- No fork marker here: the frontmatter fold stays a plain string.
assert(fold.text(1, 3) == "▸ options", "frontmatter badge without fork: " .. vim.inspect(fold.text(1, 3)))

-- A fork is a session-level fact and badges the frontmatter fold.
local fork_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(fork_buf)
vim.api.nvim_buf_set_lines(fork_buf, 0, -1, false, {
  "---",
  "description: fork",
  "---",
  "",
  "# @system",
  "",
  "helpful",
  "",
  "# @user",
  "",
  "go",
  "",
  '<!-- yap:event {"type":"session_forked","source":"file:///src","ts":"2025-09-29T19:22:33Z"} -->',
  "",
})
local fork_chunks = fold.text(1, 3)
assert(type(fork_chunks) == "table", "fork badge missing")
assert(fork_chunks[1][1] == "[Forked] " and fork_chunks[1][2] == "Comment", vim.inspect(fork_chunks[1]))
assert(fork_chunks[2][1]:find("▸ options", 1, true), vim.inspect(fork_chunks[2]))

print("OK event badges")
