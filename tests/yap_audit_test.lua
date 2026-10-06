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

-- the audit log (~/.yap/audit/<cwd-slug>/<session>.jsonl) is JSON
-- Lines: one structured event per line, carrying everything the context
-- doesn't (full arguments, full results, one turn journal per send)
local logs = vim.fn.glob(vim.fn.expand("~") .. "/.yap/audit/*/*.jsonl", false, true)
assert(#logs == 1, "expected one audit log, got: " .. vim.inspect(logs))
local events = {}
for _, line in ipairs(vim.fn.readfile(logs[1])) do
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
  turn and turn.model == "m1" and turn.prompt > 0 and turn.completion > 0 and turn.cost,
  "no turn journal: " .. vim.inspect(turn)
)

-- the audit view renders the same events: a one-line entry per tool
-- call, the full result, and the turn journal
local audit
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b):match("%-audit$") then
    audit = b
  end
end
assert(audit, "no audit view buffer")
local text = table.concat(vim.api.nvim_buf_get_lines(audit, 0, -1, false), "\n")
assert(text:match("• write /tmp/ml%-test%.md"), "no tool journal line in audit view: " .. text)
assert(text:match("Successfully wrote 250 bytes"), "tool result not rendered in audit view: " .. text)
assert(text:match("# .- turn m1:"), "no turn journal in audit view: " .. text)

-- :YapClear points each placeholder at the exact JSONL lines it replaced
-- (tool_call → tool_result for the write call: lines 1-2)
yap.clear(buf, 0)
local cleared = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(
  cleared:match("%[output cleared — full output in the audit log: .-%.jsonl:1%-2%]"),
  "placeholder missing exact line ref: " .. cleared
)
print("OK audit")
