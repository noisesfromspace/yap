-- Audit alerts remain reviewable after reopening a session. The picker
-- identifies the session and lands on the selected advisory, even folded.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local first = yap.new()
local path1 = vim.b[first].yap_path
local second = yap.new()
local path2 = vim.b[second].yap_path
local paths = require("harness.path")
local function add(buf, id, reason)
  local log = paths.audit_path(buf)
  vim.fn.mkdir(vim.fn.fnamemodify(log, ":h"), "p")
  vim.fn.writefile({
    vim.json.encode({
      type = "output",
      data = 'diff --git a/test b/test\n+if text:find("⚠ alert [", 1, true) or text:find("approval requested [", 1, true) then',
      ts = "2026-01-01T11:59:59",
    }),
    vim.json.encode({
      type = "alert_advice",
      id = id,
      name = "bash",
      reason = reason,
      p_alert = 0.42,
      severity = 1.3,
      ts = "2026-01-01T12:00:00",
    }),
    vim.json.encode({
      type = "turn_end",
      ts = "2026-01-01T12:00:01",
      prompt = 1,
      completion = 1,
    }),
  }, log, "a")
end
add(first, "first-id", "first warning")
add(first, "first-id", "later warning") -- ids can repeat across turns
local log = paths.audit_path(first)
vim.fn.writefile({
  vim.json.encode({
    type = "output",
    data = 'diff --git a/lua/harness/init.lua b/lua/harness/init.lua\n+if text:find("approval requested [", 1, true) then',
    ts = "2026-01-02T11:59:59",
  }),
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
add(second, "second-id", "second warning")
-- Rebuild audit buffers from the persisted JSONL, as on a fresh Neovim.
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b):match("%-audit$") then
    vim.api.nvim_buf_delete(b, { force = true })
  end
end
vim.cmd("enew")
vim.api.nvim_buf_delete(first, { force = true })
vim.api.nvim_buf_delete(second, { force = true })
local selected, labels
local old_select = vim.ui.select
vim.ui.select = function(items, opts, cb)
  labels = vim.tbl_map(opts.format_item, items)
  for _, item in ipairs(items) do
    if item.event.type == "approval_request" then
      selected = item
      break
    end
  end
  cb(selected)
end
vim.cmd("YapAlerts")
vim.ui.select = old_select
assert(selected and #labels == 4, "alerts picker did not list advisories and approvals: " .. vim.inspect(labels))
assert(table.concat(labels, "\n"):find("approval requested", 1, true), "approval not identified in picker")
assert(table.concat(labels, "\n"):find(vim.fn.fnamemodify(path1, ":t"), 1, true), "first session unidentified")
assert(table.concat(labels, "\n"):find(vim.fn.fnamemodify(path2, ":t"), 1, true), "second session unidentified")
local audit = vim.api.nvim_get_current_buf()
assert(
  vim.api.nvim_buf_get_name(audit):find(vim.fn.fnamemodify(path1, ":t") .. "-audit", 1, true),
  "wrong session opened"
)
local line = vim.api.nvim_win_get_cursor(0)[1]
assert(
  vim.api.nvim_buf_get_lines(audit, line - 1, line, false)[1]:find("approval requested [approval-1]", 1, true),
  "landed on quoted diff rather than approval event"
)
assert(
  vim.api.nvim_buf_get_lines(audit, line - 1, line, false)[1]:find("possible data loss", 1, true),
  "not on chosen approval"
)
assert(
  vim.api.nvim_buf_get_lines(audit, line - 1, line, false)[1]:find("rm -rf important", 1, true),
  "full blocked command not shown"
)
assert(vim.fn.foldclosed(line) == -1, "approval is still folded")
-- A quoted alert line must not displace a later advisory either.
vim.ui.select = function(items, _, cb)
  for _, item in ipairs(items) do
    if item.event.reason == "later warning" then
      cb(item)
      return
    end
  end
  error("later warning missing")
end
vim.cmd("YapAlerts")
vim.ui.select = old_select
local n = vim.api.nvim_win_get_cursor(0)[1]
assert(
  vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), n - 1, n, false)[1]:find("later warning", 1, true),
  "later advisory landed on quoted audit output"
)
-- Live append must use the same event positions as replay, regardless of
-- output text that looks like an alert.
local view = vim.api.nvim_create_buf(false, true)
vim.bo[view].modifiable = true
local audit_renderer = require("harness.audit")
local has, reviews = audit_renderer.rebuild(view, {})
local live = { bufnr = view, has_content = has, reviews = reviews }
audit_renderer.append(live, { type = "output", data = "diff\n+approval requested [fake]" })
audit_renderer.append(live, { type = "alert_advice", id = "real", name = "bash", reason = "real warning" })
assert(#live.reviews == 1, "quoted output counted as a live alert")
assert(
  vim.api.nvim_buf_get_lines(view, live.reviews[1] - 1, live.reviews[1], false)[1]:find("real warning", 1, true),
  "live review position does not point to its event"
)
print("OK alerts")
