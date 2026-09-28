-- pitel folding — ported from fruit.nvim's view.lua, adapted to pitel's
-- live markdown buffer: instead of re-rendering a JSONL session into a
-- read-only view, folds sit directly on the `# @role` headings of the
-- editable buffer. Streaming appends and edits recompute folds naturally.

local M = {}

local HEAD = "^# @(%a+)%s*$"

-- Level-2 folds inside a message fold:
--   <!-- pitel:tool … <!-- /pitel:tool -->   the WHOLE region: header
--       (single-line JSON or pretty multi-line), result text and the
--       pitel:ui diff — one fold, `▸ tool: <name>`.
--   <!-- pitel:thinking … -->                model reasoning
--   <!-- pitel:error … -->                   backend error record
-- Single-line markers (`<!-- pitel:usage … -->`) stay unfolded level-1
-- content.
local TOOL_OPEN = "^<!%-%- pitel:tool"
local TOOL_CLOSE = "^<!%-%- /pitel:tool"
-- Multi-line comment opener (nothing but the word after `pitel:`).
local COMMENT_OPEN = "^<!%-%-.*pitel:%a+%s*$"

-- The three view levels, bound to <leader>1..3 (the system prompt stays
-- folded in all of them until opened manually):
--   1: agent output hidden — only user prompts open
--   2: conversation visible — tool calls, thinking and other display
--      regions folded away
--   3: everything open
M.views = {
  { key = "1", label = "agent output folded" },
  { key = "2", label = "tools & thinking folded" },
  { key = "3", label = "everything open" },
}

local function compact(s)
  return (s or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

-- ─── foldexpr / foldtext ───────────────────────────────────────────────────

-- The region a line belongs to, found by scanning up: "tool" or
-- "comment" when lnum is inside an unclosed region, "top" at message
-- level (a heading or tool closer came first), nil when nothing
-- structural was found. pitel comments never nest; a bare `-->` above
-- means the comment whose opener lies further up is already closed, so
-- skip past it (depth counter). Bounded: marker lines are escaped in
-- tool results, and pretty-printed header JSON never starts a line with
-- `<!--` or `-->`.
local function enclosing(lnum)
  local depth = 0
  for i = lnum - 1, 1, -1 do
    local s = vim.fn.getline(i)
    if s == "-->" then
      depth = depth + 1
    elseif s:match(HEAD) or s:match(TOOL_CLOSE) then
      return "top"
    elseif s:match(COMMENT_OPEN) and not s:match("%-%->") then
      if depth > 0 then
        depth = depth - 1
        if s:match(TOOL_OPEN) then
          -- The closed comment was the multi-line tool header; the
          -- region around it is still open.
          return "tool"
        end
      else
        return s:match(TOOL_OPEN) and "tool" or "comment"
      end
    elseif depth == 0 and s:match(TOOL_OPEN) then
      return "tool" -- single-line header closes its comment on the line
    end
  end
  return nil
end

function M.expr(lnum)
  local line = vim.fn.getline(lnum)
  if line:match(HEAD) then
    return ">1"
  end
  if line:match(TOOL_OPEN) then
    return ">2" -- both header forms start the region fold
  end
  if line:match(COMMENT_OPEN) and not line:match("%-%->") then
    -- A comment opener inside a tool region (pitel:ui) is content of the
    -- region fold, not a fold of its own.
    return enclosing(lnum) == "tool" and "2" or ">2"
  end
  if line:match(TOOL_CLOSE) then
    return "2" -- the closer is the region fold's last line
  end
  local e = enclosing(lnum)
  if e == "tool" or e == "comment" then
    return "2"
  end
  return e == "top" and "1" or "="
end

function M.text(start, finish)
  start = start or vim.v.foldstart
  finish = finish or vim.v.foldend
  local first = vim.fn.getline(start)

  if first:match(TOOL_OPEN) then
    -- The name is on the opener line (single-line header) or in the
    -- pretty JSON below (multi-line header).
    local name = first:match('"name":%s*"([^"]+)"')
    for lnum = start + 1, math.min(finish, start + 12) do
      if name then
        break
      end
      name = vim.fn.getline(lnum):match('"name":%s*"([^"]+)"')
    end
    return string.format("▸ tool: %s (%d lines)", name or "?", finish - start + 1)
  end

  local region = first:match("^<!%-%-.*(pitel:%a+)")
  if region then
    return string.format("▸ %s (%d lines)", region, finish - start + 1)
  end

  local role = first:match(HEAD) or "?"

  local preview = ""
  for lnum = start + 1, finish do
    local s = compact(vim.fn.getline(lnum))
    if s ~= "" then
      preview = s
      break
    end
  end
  if #preview > 60 then
    preview = preview:sub(1, 60) .. "…"
  elseif preview == "" then
    preview = "(empty)"
  end

  return string.format("▸ @%s │ %s (%d lines)", role, preview, finish - start + 1)
end

-- ─── View levels ───────────────────────────────────────────────────────────

-- The Ⓕ chip in the winbar: the last view APPLIED to the buffer
-- (1 agent output folded, 2 tools & thinking folded, 3 all open). It
-- used to be measured from foldclosed(), but that read as confusing —
-- after <leader>3 the chip showed Ⓕ0. Trade-off: manual za toggles no
-- longer update the chip.
local applied = {}

function M.level()
  return applied[vim.api.nvim_get_current_buf()] or 3
end

-- Close the message folds a view hides — MANUALLY, never via
-- 'foldlevel'=0 + foldopen. A manual OPEN on a fold is inherited by
-- child folds created later (a tool region streaming into the opened
-- assistant block would appear open), while a manual CLOSE stays
-- local, and brand-new folds simply follow 'foldlevel': 1 keeps
-- messages open and regions folded. The system prompt is reference
-- material: folded in every view until opened manually (za).
local function close_message_folds(keep_user)
  for lnum = 1, vim.api.nvim_buf_line_count(0) do
    local role = vim.fn.getline(lnum):match(HEAD)
    if role and (role == "system" or (keep_user and role ~= "user")) then
      pcall(vim.cmd, string.format("silent! %dfoldclose", lnum))
    end
  end
end

-- Open/close state per view: 'foldlevel' is 1 (views 1/2) or 99 (view
-- 3), then the folds the view hides are closed manually. A real CHANGE
-- of 'foldlevel' resets all manual za toggles to the level's state, so
-- bump first to guarantee the change — a keypress always lands on the
-- same state. Between keypresses NOTHING touches fold state: new folds
-- adopt 'foldlevel' (streamed tool regions appear folded in views 1/2,
-- open in 3), manual za persists, typing changes nothing.
function M.set_view_level(level)
  applied[vim.api.nvim_get_current_buf()] = level
  -- Force the next set to be a real change (resetting manual toggles).
  vim.wo.foldlevel = level == 3 and 98 or 99
  vim.wo.foldlevel = level == 3 and 99 or 1
  close_message_folds(level == 1) -- view 1 keeps only user prompts open
end

-- ─── Message navigation ────────────────────────────────────────────────────

local function jump(pattern, backwards)
  vim.fn.search(pattern, backwards and "bW" or "W")
end

-- Vim-regex equivalents of HEAD for search() (Lua patterns don't apply).
-- No trailing anchor: in Vim regex \s also matches EOL, spilling the
-- match onto the next line.
local VIM_HEAD = [[^# @\a\+]]
local VIM_USER = [[^# @user]]
local VIM_ASSISTANT = [[^# @assistant]]

function M.next_message()
  jump(VIM_HEAD, false)
end

function M.prev_message()
  jump(VIM_HEAD, true)
end

function M.next_user_message()
  jump(VIM_USER, false)
end

function M.prev_user_message()
  jump(VIM_USER, true)
end

function M.next_assistant_message()
  jump(VIM_ASSISTANT, false)
end

function M.prev_assistant_message()
  jump(VIM_ASSISTANT, true)
end

-- ─── Buffer setup ──────────────────────────────────────────────────────────

function M.setup_buffer(buf)
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require'harness.fold'.expr(v:lnum)"
  vim.wo.foldtext = "v:lua.require'harness.fold'.text()"
  vim.wo.foldlevel = 99 -- expr folds start computable; default state applied below
  M.set_view_level(1) -- default: an overview — only user prompts open

  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  map("]m", M.next_message, "Next message")
  map("[m", M.prev_message, "Previous message")
  map("]u", M.next_user_message, "Next user message")
  map("[u", M.prev_user_message, "Previous user message")
  map("]a", M.next_assistant_message, "Next assistant message")
  map("[a", M.prev_assistant_message, "Previous assistant message")
  local bind_view = function(key, level, desc)
    map(key, function()
      M.set_view_level(level)
    end, desc)
  end
  bind_view("<leader>1", 1, "Fold all agent messages (user prompts stay open)")
  bind_view("<leader>2", 2, "Fold all tool calls and thinking blocks")
  bind_view("<leader>3", 3, "Unfold everything")
  map("<Tab>", "za", "Toggle fold")
end

return M
