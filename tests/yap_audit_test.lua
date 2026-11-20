local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })
local buf = yap.new({ provider = "mock", model = "gpt-4o" })
yap.send()
local ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):match("File written%.") ~= nil
end, 100)
assert(ok, "send did not complete")
vim.wait(300) -- let the last scheduled event handlers run

-- the audit log (<name>.jsonl next to <name>.md) is JSON Lines: one
-- structured event per line, carrying everything the context doesn't
-- (full arguments, full results, one turn journal per send)
local log = require("harness.path").audit_path(buf)
assert(vim.fn.filereadable(log) == 1, "audit log not written")
local events = {}
for _, line in ipairs(vim.fn.readfile(log)) do
  if line ~= "" then
    local ok, ev = pcall(vim.json.decode, line)
    assert(ok and type(ev) == "table", "malformed audit line: " .. line)
    events[#events + 1] = ev
  end
end

local function find(t, name)
  for _, e in ipairs(events) do
    if e.type == t and e.name == name then
      return e
    end
  end
end

local call = find("tool_call", "write")
assert(call and call.args:match("line one about dogs"), "full write args not in audit")
assert(call.ts, "tool_call missing ts")
local result = find("tool_result", "write")
assert(result and result.result:match("Successfully wrote 250 bytes"), "full tool result not in audit")
assert(
  tonumber(result.bytes) ~= nil and tonumber(result.bytes) > 0,
  "tool_result bytes wrong: " .. tostring(result.bytes)
)
local turn
for _, e in ipairs(events) do
  if e.type == "turn_end" then
    turn = e
  end
end
assert(
  turn and turn.model == "gpt-4o" and turn.prompt > 0 and turn.completion > 0 and turn.cost,
  "no turn journal: " .. vim.inspect(turn)
)
assert(turn.context_prompt and turn.context_prompt > 0, "turn_end missing full prompt size: " .. vim.inspect(turn))
assert(turn.cache_read == nil and turn.cache_write == nil, "provider without cache info should omit cache fields")

-- Per-step usage is durable: one line per model step, carrying its own split
-- beside the cumulative totals the winbar chips read.
local steps = {}
for _, e in ipairs(events) do
  if e.type == "usage" then
    steps[#steps + 1] = e
  end
end
assert(#steps > 0, "no per-step usage lines in the audit log")
assert(steps[1].step == 1, "first usage line should be step 1: " .. vim.inspect(steps[1]))
assert(
  steps[1].step_prompt ~= nil and steps[1].step_cache_read ~= nil and steps[1].step_completion ~= nil,
  "usage line missing its per-step split: " .. vim.inspect(steps[1])
)

-- :YapClear points each placeholder at the exact JSONL lines it replaced
-- (tool_call → tool_result for the write call; turn_start opens the log and
-- that step's usage line follows, so the two records are lines 3-4)
yap.clear(buf, 0)
local cleared = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(
  cleared:match("%[output cleared — full output in the audit log: .-%.jsonl:3%-4%]"),
  "placeholder missing exact line ref: " .. cleared
)
print("OK audit")
