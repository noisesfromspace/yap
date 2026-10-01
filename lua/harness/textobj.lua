-- yap text objects: operate on the buffer's structure — a whole message
-- (`# @role` block) or a display block (thinking/tool/error marker region).
--
--   im / am   inner / a message      (content without heading / whole block)
--   it / at   inner / a block        (content without markers / whole region)
--
-- so `dit` clears a thinking/tool block, `dat` removes it entirely, `cim`
-- replaces a message body while keeping its `# @role` heading, `dam` drops
-- a message wholesale.
--
-- Standard Vim text-object recipe (:h text-object-define): the visual-mode
-- mapping is an <expr> that brackets the range with the '[ '] marks and
-- returns "`[o`]"; the operator-pending mapping just re-enters visual mode
-- with `:normal v…`, so the pending operator applies to that selection.

local M = {}

local HEAD = "^# @(%a+)%s*$"
local VIM_HEAD = [[^# @\a\+]] -- Vim-regex twin for vim.fn.search()

-- Marker regions. A tool block is `<!-- yap:tool` … `<!-- /yap:tool`; any
-- other multi-line `<!-- yap:<word>` comment (thinking, error, legacy ui)
-- closes on a bare `-->`. Single-line markers (`<!-- yap:usage … -->`) never
-- match COMMENT_OPEN, so they stay content.
local TOOL_OPEN = "^<!%-%- yap:tool"
local TOOL_CLOSE = "^<!%-%- /yap:tool"
local COMMENT_OPEN = "^<!%-%-%s*yap:%a+%s*$"
local COMMENT_CLOSE = "^%-%->%s*$"

-- ─── Range finders ─────────────────────────────────────────────────────────

--- Heading line (1-based) of the message containing `lnum`, or nil when
--- `lnum` sits before the first `# @role` heading.
local function message_heading(lnum)
  if vim.fn.getline(lnum):match(HEAD) then
    return lnum
  end
  local orig = vim.fn.getpos(".")
  vim.fn.cursor(lnum, 1)
  local heading = vim.fn.search(VIM_HEAD, "bnW")
  vim.fn.setpos(".", orig)
  if heading == 0 then
    return nil
  end
  return heading
end

--- heading, next_heading (exclusive) for the message containing `lnum`.
local function message_range(lnum)
  local heading = message_heading(lnum)
  if not heading then
    return nil
  end
  local orig = vim.fn.getpos(".")
  vim.fn.cursor(heading + 1, 1)
  local nxt = vim.fn.search(VIM_HEAD, "nW")
  vim.fn.setpos(".", orig)
  if nxt == 0 then
    nxt = vim.fn.line("$") + 1
  end
  return heading, nxt
end

--- Innermost block region containing `lnum`, or nil. Scans forward from the
--- enclosing message heading (blocks only exist inside messages and never
--- nest), so a fake heading inside a fenced tool result can't be mistaken
--- for a block boundary.
local function block_range(lnum)
  local heading = message_heading(lnum)
  if not heading then
    return nil
  end
  local total = vim.fn.line("$")
  local tool_open, comment_open = nil, nil
  for i = heading, total do
    local line = vim.fn.getline(i)
    if tool_open then
      if line:match(TOOL_CLOSE) then
        if lnum >= tool_open and lnum <= i then
          return { open = tool_open, close = i }
        end
        tool_open = nil
      end
    elseif comment_open then
      if line:match(COMMENT_CLOSE) then
        if lnum >= comment_open and lnum <= i then
          return { open = comment_open, close = i }
        end
        comment_open = nil
      end
    else
      if line:match(TOOL_OPEN) then
        tool_open = i
      elseif line:match(COMMENT_OPEN) then
        comment_open = i
      end
    end
  end
  return nil
end

-- ─── Selection ─────────────────────────────────────────────────────────────

-- Bracket `l1..l2` (1-based, inclusive) as a charwise range (inner objects):
-- from column 1 of l1 through the last character of l2.
local function char_range(l1, l2)
  local lastcol = math.max(1, #vim.fn.getline(l2))
  vim.fn.setpos("'[", { 0, l1, 1, 0 })
  vim.fn.setpos("']", { 0, l2, lastcol, 0 })
  return "`[o`]"
end

-- Bracket `l1..l2` as a linewise range (outer objects).
local function line_range(l1, l2)
  vim.fn.setpos("'[", { 0, l1, 1, 0 })
  vim.fn.setpos("']", { 0, l2, 1, 0 })
  return "`[o`]"
end

local function inner_message()
  local heading, nxt = message_range(vim.fn.line("."))
  if not heading then
    return "\27"
  end
  local first, last = heading + 1, nxt - 1
  while first <= last and vim.fn.getline(first):match("^%s*$") do
    first = first + 1
  end
  while last >= first and vim.fn.getline(last):match("^%s*$") do
    last = last - 1
  end
  if last < first then
    return "\27"
  end
  return char_range(first, last)
end

local function around_message()
  local heading, nxt = message_range(vim.fn.line("."))
  if not heading then
    return "\27"
  end
  return line_range(heading, nxt - 1)
end

local function inner_block()
  local b = block_range(vim.fn.line("."))
  if not b or b.close - 1 < b.open + 1 then
    return "\27"
  end
  return char_range(b.open + 1, b.close - 1)
end

local function around_block()
  local b = block_range(vim.fn.line("."))
  if not b then
    return "\27"
  end
  return line_range(b.open, b.close)
end

-- ─── Buffer setup ──────────────────────────────────────────────────────────

function M.setup_buffer(buf)
  local map = function(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, expr = true, silent = true, desc = desc })
  end
  -- Visual-mode <expr> mappings bracket the range and select it.
  map("x", "im", inner_message, "yap: inner message")
  map("x", "am", around_message, "yap: a message")
  map("x", "it", inner_block, "yap: inner block")
  map("x", "at", around_block, "yap: a block")

  -- Operator-pending mappings re-enter visual mode (charwise for inner,
  -- linewise for outer); the pending operator then applies to the selection.
  vim.keymap.set("o", "im", function()
    vim.cmd.normal("vim")
  end, { buffer = buf, silent = true, desc = "yap: inner message" })
  vim.keymap.set("o", "am", function()
    vim.cmd.normal("Vam")
  end, { buffer = buf, silent = true, desc = "yap: a message" })
  vim.keymap.set("o", "it", function()
    vim.cmd.normal("vit")
  end, { buffer = buf, silent = true, desc = "yap: inner block" })
  vim.keymap.set("o", "at", function()
    vim.cmd.normal("Vat")
  end, { buffer = buf, silent = true, desc = "yap: a block" })
end

return M
