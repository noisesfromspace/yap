-- :YapAudit (split-panel JSONL browser) and the audit-view polish: turn
-- folding (a table of contents) and per-line highlighting.
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

local log = vim.fn.glob(vim.fn.expand("~") .. "/.yap/audit/*/*.jsonl", false, true)[1]
assert(log and vim.fn.filereadable(log) == 1, "audit log missing")

-- ─── audit view: turn folding + highlighting ────────────────────────────
yap.live()
local audit = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(audit):match("%-audit$"), "live did not open the audit view")
local header
for i, l in ipairs(vim.api.nvim_buf_get_lines(audit, 0, -1, false)) do
  if l:match("^# %d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d turn ") then
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

-- ─── :YapAudit split-panel viewer ──────────────────────────────────────
yap.live() -- close the audit view drawer
local audit = require("harness.audit")
audit.view()
-- current window is the preview (rightmost); the source is one window left.
assert(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()) == "yap://audit-preview", "preview not open")
local preview = vim.api.nvim_get_current_buf()
vim.cmd("wincmd h")
local source = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(source) == "yap://audit:" .. log, "source pane is not the audit log: " .. vim.api.nvim_buf_get_name(source))
assert(vim.bo[source].buftype == "nofile" and not vim.bo[source].modifiable, "source pane should be read-only")
-- one source line per raw audit line, so :YapClear line refs stay exact
assert(vim.api.nvim_buf_line_count(source) == #vim.fn.readfile(log), "source line count != audit log")
-- line 1 is the write tool_call; the preview renders it readably
local preview_text = table.concat(vim.api.nvim_buf_get_lines(preview, 0, -1, false), "\n")
assert(preview_text:match('"type": "tool_call"'), "preview missing type field: " .. preview_text)
assert(preview_text:match('"name": "write"'), "preview missing name field: " .. preview_text)
-- moving to the tool_result line updates the preview to the result body
local result_line
for i, l in ipairs(vim.fn.readfile(log)) do
  if l:match('"type"%s*:%s*"tool_result"') then
    result_line = i
    break
  end
end
assert(result_line, "no tool_result in audit log")
vim.api.nvim_win_set_cursor(vim.fn.win_findbuf(source)[1], { result_line, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source })
preview_text = table.concat(vim.api.nvim_buf_get_lines(preview, 0, -1, false), "\n")
assert(preview_text:match('"type": "tool_result"'), "preview did not update to the result: " .. preview_text)
assert(preview_text:match("Successfully wrote"), "result body missing from preview: " .. preview_text)
print("OK audit-view")
