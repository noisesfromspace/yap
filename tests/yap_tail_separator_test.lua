-- The live tool tail separates consecutive commands with a horizontal rule
-- and highlights each `$ command` header, so dense streamed output reads as
-- distinct blocks.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local audit = require("harness.audit")

local buf = vim.api.nvim_create_buf(true, true)
vim.api.nvim_buf_set_name(buf, "tail-sep-test")

-- First command: a fresh tail starts directly at the header, no rule above.
audit.tool_start(buf, "echo one && echo two")
-- Second command: preceded by a blank line and a rule separator.
audit.tool_start(buf, "echo three")

local tail = audit.view(buf).bufnr
local lines = vim.api.nvim_buf_get_lines(tail, 0, -1, false)

assert(lines[1] == "$ echo one", "first header wrong: " .. lines[1])
assert(lines[2] == "  && echo two", "first header continuation wrong: " .. lines[2])
assert(lines[3] == "", "missing blank line before the separator: " .. vim.inspect(lines))
assert(lines[4] ~= "" and lines[4]:gsub("─", "") == "", "no rule separator before the second command: " .. vim.inspect(lines))
assert(lines[5] == "$ echo three", "second header wrong: " .. lines[5])

-- Each `$ command` header is highlighted; the rule separator is not.
local ns = vim.api.nvim_get_namespaces()["yap.audit.hl"]
assert(ns, "audit highlight namespace missing")
local function hl_on(line)
  local row = line - 1
  local marks = vim.api.nvim_buf_get_extmarks(tail, ns, { row, 0 }, { row, 0 }, { details = true })
  for _, m in ipairs(marks) do
    if m[4] and m[4].hl_group == "YapAuditCommand" then
      return true
    end
  end
  return false
end
assert(hl_on(1), "first header not highlighted")
assert(hl_on(2), "first header continuation not highlighted")
assert(not hl_on(4), "rule separator should not be highlighted")
assert(hl_on(5), "second header not highlighted")

-- A rule drawn with no window uses the background fallback width; once a
-- window shows the tail, refresh() re-renders it to that window's width.
assert(vim.fn.strchars(lines[4]) == 80, "expected the background fallback width, got: " .. vim.fn.strchars(lines[4]))
vim.api.nvim_open_win(tail, false, { relative = "editor", width = 40, height = 5, row = 0, col = 0 })
audit.refresh(buf)
local resized = vim.api.nvim_buf_get_lines(tail, 0, -1, false)
assert(vim.fn.strchars(resized[4]) == 40, "rule did not resize to the window width: " .. vim.fn.strchars(resized[4]))

print("OK tail separator")
