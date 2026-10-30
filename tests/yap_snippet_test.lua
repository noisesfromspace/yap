-- Role-heading shorthand: `# @`, `# @a` and `# @s` followed by a space expand
-- to a full heading with the cursor in the body. A full heading or ordinary
-- prose is left alone, and a bare `# @` (no space) stays in the buffer so the
-- LSP role completion can still offer user/assistant/system.

local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local snippet = require("harness.client.snippet")

-- The shorthand trigger defers its edit through vim.schedule (InsertCharPre
-- forbids buffer edits). Capture and run scheduled callbacks deterministically.
local real_schedule = vim.schedule
local pending = {}
vim.schedule = function(fn)
  pending[#pending + 1] = fn
end
local function flush()
  local q = pending
  pending = {}
  for _, fn in ipairs(q) do
    fn()
  end
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.b[buf].yap = true
snippet.setup_buffer(buf)

local function lines()
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end
local function reset()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end
-- Type `str` in insert mode and run any queued snippet edit, then leave
-- insert mode.
local function type(str)
  vim.api.nvim_feedkeys("i" .. str, "xt", false)
  flush()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
end

-- 1. Bare `# @` expands to the user heading: heading, blank line, empty body.
reset()
type("# @ ")
assert(
  table.concat(lines(), "\n") == "# @user\n\n",
  "bare shorthand did not expand to # @user: " .. vim.inspect(lines())
)
assert(vim.api.nvim_win_get_cursor(0)[1] == 3 and vim.api.nvim_win_get_cursor(0)[2] == 0, "cursor not in the body")

-- 2. `# @a` is assistant prefill; `# @s` is system.
reset()
type("# @a ")
assert(table.concat(lines(), "\n") == "# @assistant\n\n", "`# @a` did not expand to assistant")
reset()
type("# @s ")
assert(table.concat(lines(), "\n") == "# @system\n\n", "`# @s` did not expand to system")

-- 3. A full heading is left alone: typing the role out does not expand.
reset()
type("# @user ")
assert(table.concat(lines(), "\n") == "# @user ", "full heading was expanded")
reset()
type("# @assistant ")
assert(table.concat(lines(), "\n") == "# @assistant ", "full assistant heading was expanded")
reset()
type("# @system ")
assert(table.concat(lines(), "\n") == "# @system ", "full system heading was expanded")

-- 4. Prose is left alone: a space after other text does not expand.
reset()
type("hello ")
assert(table.concat(lines(), "\n") == "hello ", "prose was expanded")

-- 5. A bare `# @` without a space stays in the buffer, so the LSP role
-- completion still has a heading to complete.
reset()
type("# @")
assert(table.concat(lines(), "\n") == "# @", "bare shorthand without space was expanded")

-- 6. A bare `# @` whose line was rewritten by the completion's auto-select
-- (completeopt without `noselect` inserts `# @assistant`) still expands to the
-- default `# @user` on space. The trigger tracks the keystrokes, not the line.
reset()
type("# @") -- opens the bare shorthand
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @assistant" }) -- completion auto-selected
local function append(str)
  vim.api.nvim_feedkeys("A" .. str, "xt", false)
  flush()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
end
append(" ")
assert(
  table.concat(lines(), "\n") == "# @user\n\n",
  "auto-selected role was not expanded to the default: " .. vim.inspect(lines())
)

-- 7. The same heading typed out letter by letter is not a bare shorthand and
-- stays put (the `a` after `# @` ended the bare state).
reset()
type("# @assistant ")
assert(table.concat(lines(), "\n") == "# @assistant ", "typed heading was collapsed")

-- Restore vim.schedule before exit (VimLeavePre handlers rely on it).
vim.schedule = real_schedule

print("yap snippet: role-heading shorthand expands on space")
