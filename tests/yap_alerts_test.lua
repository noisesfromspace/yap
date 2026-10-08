-- Advisories and resolved approvals remain reviewable after reopening a
-- session: the guard board's Open section lists recent advisories, History
-- lists resolved approvals, and the audit renderer still distinguishes real
-- review events from output text that merely quotes one.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local first = yap.new()
local paths = require("harness.path")
local guard = require("harness.guard")

local function add(buf, id, reason, ts)
  local log = paths.audit_path(buf)
  vim.fn.mkdir(vim.fn.fnamemodify(log, ":h"), "p")
  vim.fn.writefile({
    vim.json.encode({ type = "tool_call", id = id, name = "bash", args = '{"command":"echo warning"}' }),
    vim.json.encode({
      type = "alert_advisory",
      id = id,
      name = "bash",
      reason = reason,
      p_alert = 0.42,
      severity = 1.3,
      confidence = 0.55,
      severity_category = "reversible",
      severity_category_prob = 0.97,
      ts = ts,
    }),
    vim.json.encode({ type = "turn_end", ts = ts, prompt = 1, completion = 1 }),
  }, log, "a")
end
local now = os.date("%Y-%m-%dT%H:%M:%S")
add(first, "first-id", "first warning", now)
add(first, "first-id", "later warning", now)
-- An advisory older than the recency window lands in History, not Open.
add(first, "old-id", "old warning", "2026-01-01T12:00:00")
-- A denied approval lands in History.
local log = paths.audit_path(first)
vim.fn.writefile({
  vim.json.encode({
    type = "approval_request",
    id = "approval-1",
    tool = "bash",
    reason = "possible data loss",
    command = '{"command":"rm -rf important"}',
    ts = "2026-01-02T12:00:00",
  }),
  vim.json.encode({ type = "approval_result", id = "approval-1", approved = false, ts = "2026-01-02T12:00:01" }),
}, log, "a")

-- Rebuild audit buffers from the persisted JSONL, as on a fresh Neovim.
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b):match("%-audit$") then
    vim.api.nvim_buf_delete(b, { force = true })
  end
end
vim.cmd("enew")
vim.api.nvim_buf_delete(first, { force = true })

guard.toggle()
local board = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(board) == "yap://guard", "guard board did not open")
local text = table.concat(vim.api.nvim_buf_get_lines(board, 0, -1, false), "\n")
-- Recent advisories sit in Open (read-only rows), with their severity badge.
assert(text:find("▸ Open (2)", 1, true), "Open section should list both recent advisories: " .. text)
assert(text:find("first warning", 1, true), "first advisory missing from board")
assert(text:find("later warning", 1, true), "second advisory missing")
assert(text:find("reversible", 1, true), "severity badge missing from board")
-- The denied approval and the old advisory sit in History.
assert(text:find("▸ History (2)", 1, true), "History section missing denied approval + old advisory: " .. text)
assert(text:find("possible data loss", 1, true), "denied approval reason missing from History")
assert(text:find("old warning", 1, true), "old advisory missing from History")
guard.toggle() -- close

-- Live append must use the same event positions as replay, regardless of
-- output text that looks like an alert.
local view = vim.api.nvim_create_buf(false, true)
vim.bo[view].modifiable = true
local audit_renderer = require("harness.audit")
local has, reviews = audit_renderer.rebuild(view, {})
local live = { bufnr = view, has_content = has, reviews = reviews }
audit_renderer.append(live, { type = "output", data = "diff\n+approval requested [fake]" })
audit_renderer.append(live, { type = "alert_advisory", id = "real", name = "bash", reason = "real warning" })
assert(#live.reviews == 1, "quoted output counted as a live alert")
assert(
  vim.api.nvim_buf_get_lines(view, live.reviews[1] - 1, live.reviews[1], false)[1]:find("real warning", 1, true),
  "live review position does not point to its event"
)
print("OK alerts")
