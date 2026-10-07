-- yap text objects: operate on the buffer's structure — a whole message
-- (`# @role` message) or a display region (thinking/tool/error marker region).
--
--   im / am   inner / a message      (content without heading / whole message)
--   it / at   inner / a region       (content without markers / whole region)
--
-- so `dit` clears a thinking/tool region, `dat` removes it entirely, `cim`
-- replaces a message body while keeping its `# @role` heading, `dam` drops
-- a message wholesale.
--
-- Standard Vim text-object recipe (:h text-object-define): the visual-mode
-- mapping is an <expr> that brackets the range with the '[ '] marks and
-- returns "`[o`]"; the operator-pending mapping just re-enters visual mode
-- with `:normal v…`, so the pending operator applies to that selection.

local M = {}

local fold = require("harness.fold")

-- ─── Range finders ─────────────────────────────────────────────────────────

--- Heading line (1-based) of the message containing `lnum`, or nil when
--- `lnum` sits before the first `# @role` heading. Headings come from the
--- structural parse folding uses, so a `# @user` line inside a fenced tool
--- result can never be mistaken for a message boundary.
local function message_heading(lnum)
  local buf = vim.api.nvim_get_current_buf()
  local heading
  for _, h in ipairs(fold.parse(buf).headings) do
    if h.line <= lnum then
      heading = h.line
    else
      break
    end
  end
  return heading
end

--- heading, next_heading (exclusive) for the message containing `lnum`.
local function message_range(lnum)
  local heading = message_heading(lnum)
  if not heading then
    return nil
  end
  local nxt
  for _, h in ipairs(fold.parse(vim.api.nvim_get_current_buf()).headings) do
    if h.line > heading then
      nxt = h.line
      break
    end
  end
  return heading, nxt or (vim.fn.line("$") + 1)
end

-- The same cached scan used for folding and navigation recognizes region
-- boundaries and ignores marker-looking lines inside fenced tool results.
local function region_range(lnum)
  for _, detail in ipairs(fold.parse(vim.api.nvim_get_current_buf()).regions) do
    if detail.finish and detail.start <= lnum and lnum <= detail.finish then
      return { open = detail.start, close = detail.finish }
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

local function inner_region()
  local b = region_range(vim.fn.line("."))
  if not b or b.close - 1 < b.open + 1 then
    return "\27"
  end
  return char_range(b.open + 1, b.close - 1)
end

local function around_region()
  local b = region_range(vim.fn.line("."))
  if not b then
    return "\27"
  end
  return line_range(b.open, b.close)
end

-- ─── Buffer setup ──────────────────────────────────────────────────────────

function M.setup_buffer(buf, keys)
  keys = keys or require("harness").config.keymaps
  local map = function(mode, lhs, rhs, desc)
    if lhs == "" then
      return
    end
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, expr = true, silent = true, desc = desc })
  end
  -- Visual-mode <expr> mappings bracket the range and select it.
  map("x", keys.inner_message, inner_message, "yap: inner message")
  map("x", keys.around_message, around_message, "yap: a message")
  map("x", keys.inner_region, inner_region, "yap: inner region")
  map("x", keys.around_region, around_region, "yap: a region")

  -- Operator-pending mappings re-enter visual mode (charwise for inner,
  -- linewise for outer); the pending operator then applies to the
  -- selection. Re-entry goes through the configured visual lhs.
  local op = function(lhs, visual_lhs, linewise, desc)
    if lhs == "" then
      return
    end
    vim.keymap.set("o", lhs, function()
      vim.cmd.normal((linewise and "V" or "v") .. visual_lhs)
    end, { buffer = buf, silent = true, desc = desc })
  end
  op(keys.inner_message, keys.inner_message, false, "yap: inner message")
  op(keys.around_message, keys.around_message, true, "yap: a message")
  op(keys.inner_region, keys.inner_region, false, "yap: inner region")
  op(keys.around_region, keys.around_region, true, "yap: a region")
end

return M
