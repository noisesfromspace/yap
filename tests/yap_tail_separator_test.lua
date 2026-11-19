-- The live tool tail separates consecutive commands with a horizontal rule
-- and highlights each `$ command` header, so dense streamed output reads as
-- distinct blocks.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local audit = require("harness.client.audit")

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
local ns = vim.api.nvim_get_namespaces()["yap.tail.hl"]
assert(ns, "tail highlight namespace missing")
local function hl_on(line)
  local row = line - 1
  local marks = vim.api.nvim_buf_get_extmarks(tail, ns, { row, 0 }, { row, 0 }, { details = true })
  for _, m in ipairs(marks) do
    if m[4] and m[4].hl_group == "YapTailCommand" then
      return true
    end
  end
  return false
end
assert(hl_on(1), "first header not highlighted")
assert(hl_on(2), "first header continuation not highlighted")
assert(not hl_on(4), "rule separator should not be highlighted")
assert(hl_on(5), "second header not highlighted")

-- Tail names follow the session description and filename title. A suffix
-- keeps two sessions with the same display name distinct.
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })
local frontmatter = require("harness.model.frontmatter")
local session = require("harness.session")
local function set_description(buf, description)
  frontmatter.update(buf, { description = description })
  session.save(buf)
end
local first = yap.new()
local first_tail = audit.ensure(first).bufnr
local fallback = "Yap Tail: " .. require("harness.path").session_name(vim.b[first].yap_path)
assert(vim.fn.bufname(first_tail) == fallback, "tail fallback name wrong: " .. vim.fn.bufname(first_tail) .. " expected " .. fallback)
set_description(first, "Fix buffer picker")
assert(vim.fn.bufname(first_tail) == "Yap Tail: Fix buffer picker", "description did not rename tail")
local second = yap.new()
local second_tail = audit.ensure(second).bufnr
set_description(second, "Fix buffer picker")
assert(
  vim.fn.bufname(second_tail) == "Yap Tail: Fix buffer picker [" .. second .. "]",
  "duplicate tail name was not disambiguated: " .. vim.fn.bufname(second_tail)
)
frontmatter.update(second, { description = "" })
vim.api.nvim_buf_set_name(second, vim.fn.fnamemodify(vim.b[second].yap_path, ":h") .. "/Named title.md")
session.save(second)
assert(vim.fn.bufname(second_tail) == "Yap Tail: Named title", "filename title fallback wrong")

-- A rule drawn with no window uses the background fallback width; once a
-- window shows the tail, refresh() re-renders it to that window's width.
assert(vim.fn.strchars(lines[4]) == 80, "expected the background fallback width, got: " .. vim.fn.strchars(lines[4]))
vim.api.nvim_open_win(tail, false, { relative = "editor", width = 40, height = 5, row = 0, col = 0 })
audit.refresh(buf)
local resized = vim.api.nvim_buf_get_lines(tail, 0, -1, false)
assert(vim.fn.strchars(resized[4]) == 40, "rule did not resize to the window width: " .. vim.fn.strchars(resized[4]))

-- Y in the live tail copies the original command from its header or output,
-- not the wrapped lines shown on screen. Separator lines do nothing.
local command = "printf 'first\\nsecond' && echo done"
audit.tool_start(first, command)
local first_view = audit.view(first)
require("harness.state").live_logs[first] = { log1 = { log = "log1", pending = "" } }
audit.tool_output(first, "log1", "result line\n")
yap.live(first)
local first_lines = vim.api.nvim_buf_get_lines(first_view.bufnr, 0, -1, false)
local header, output
for i, text in ipairs(first_lines) do
  if text:sub(1, 2) == "$ " then header = i end
  if text == "result line" then output = i end
end
assert(header and output, "missing command or output in tail")
assert(vim.fn.maparg("Y", "n", false, true).buffer == 1, "tail missing Y map")
vim.fn.setreg('"', "old")
vim.fn.setreg("+", "old")
vim.api.nvim_win_set_cursor(0, { output, 0 })
vim.api.nvim_feedkeys("Y", "mtx", false)
assert(vim.fn.getreg('"') == command and vim.fn.getreg("+") == command, "Y on output did not copy full command")
vim.fn.setreg('"', "old")
vim.api.nvim_win_set_cursor(0, { header, 0 })
vim.api.nvim_feedkeys("Y", "mtx", false)
assert(vim.fn.getreg('"') == command, "Y on header did not copy command")
audit.tool_start(first, "echo next")
local next_header = vim.api.nvim_buf_line_count(first_view.bufnr)
vim.fn.setreg('"', "old")
vim.fn.setreg("+", "old")
vim.api.nvim_win_set_cursor(0, { next_header - 1, 0 }) -- rule separator
vim.api.nvim_feedkeys("Y", "mtx", false)
assert(vim.fn.getreg('"') == "old" and vim.fn.getreg("+") == "old", "Y copied from separator")
vim.api.nvim_win_set_cursor(0, { next_header, 0 })
vim.api.nvim_feedkeys("Y", "mtx", false)
assert(vim.fn.getreg('"') == "echo next" and vim.fn.getreg("+") == "echo next", "Y copied wrong command")
yap.live(first) -- close

print("OK tail separator")
