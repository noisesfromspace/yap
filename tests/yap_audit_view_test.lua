-- The audit view (:YapLive) polish: turn folding (a table of contents),
-- per-line highlighting, and the <Tab> fold toggle.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

local buf = yap.new()
yap.send()
local ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):match("File written%.") ~= nil
end, 100)
assert(ok, "send did not complete")
vim.wait(300)

-- ─── audit view: turn folding + highlighting ────────────────────────────
yap.live()
local audit = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(audit):match("%-audit$"), "live did not open the audit view")
local header
for i, l in ipairs(vim.api.nvim_buf_get_lines(audit, 0, -1, false)) do
  if l:match("^# %d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d turn:") then
    header = i
    break
  end
end
assert(header, "no turn header in audit view")
assert(vim.fn.foldclosed(header) ~= -1, "turn not folded: " .. vim.fn.foldclosed(header))
assert(vim.fn.foldclosedend(header) == header, "turn does not fold back to its header")
local audit_ns = vim.api.nvim_get_namespaces()["yap.audit.hl"]
assert(audit_ns, "audit highlight namespace missing")
local highlighted = false
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(audit, audit_ns, { header - 1, 0 }, { header, 0 }, { details = true })) do
  if m[4].hl_group == "YapAuditTurn" then
    highlighted = true
  end
end
assert(highlighted, "turn header not highlighted")

-- ─── <Tab> toggles a folded turn ────────────────────────────────────────
local tab = vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
vim.api.nvim_win_set_cursor(0, { header, 0 })
vim.api.nvim_feedkeys(tab, "mtx", false)
assert(vim.fn.foldclosed(header) == -1, "<Tab> did not open the turn: " .. vim.fn.foldclosed(header))
vim.api.nvim_feedkeys(tab, "mtx", false)
assert(vim.fn.foldclosed(header) ~= -1, "<Tab> did not close the turn")
print("OK audit-view")
