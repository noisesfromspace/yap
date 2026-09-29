local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })
local buf = yap.new({ provider = "mock", model = "m1" })
yap.send()
local ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):match("File written%.") ~= nil
end, 100)
assert(ok, "send did not complete")
vim.wait(300) -- let the last scheduled event handlers run

-- the audit log (~/.yap/audit/<cwd-slug>/<session>.log) persists what
-- the context doesn't carry: full tool arguments, full results, and one
-- journal line per turn
local logs = vim.fn.glob(vim.fn.expand("~") .. "/.yap/audit/*/*.log", false, true)
assert(#logs == 1, "expected one audit log, got: " .. vim.inspect(logs))
local audit = table.concat(vim.fn.readfile(logs[1]), "\n")
assert(audit:match("=== .- write %{.-line one about dogs"), "full write args not in audit: " .. audit)
assert(audit:match("Successfully wrote 250 bytes"), "full tool result not in audit: " .. audit)
assert(audit:match("%-%-%- .- write %(%d+ bytes%)"), "no tool_result record: " .. audit)
assert(audit:match("# .- turn m1: %d+ in · %d+ out · %$[%d.]+ · [%d.]+s"), "no turn journal: " .. audit)

-- the tail buffer shows the same journal + a one-line entry per tool call
local tail
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b):match("%-tail$") then
    tail = b
  end
end
assert(tail, "no tail buffer")
local text = table.concat(vim.api.nvim_buf_get_lines(tail, 0, -1, false), "\n")
assert(text:match("• write /tmp/ml%-test%.md"), "no tool journal line in tail: " .. text)
assert(text:match("# .- turn m1:"), "no turn journal in tail: " .. text)
print("OK audit")
