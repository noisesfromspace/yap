-- pitel folding — ported from fruit.nvim's view.lua, adapted to pitel's
-- live markdown buffer: instead of re-rendering a JSONL session into a
-- read-only view, folds sit directly on the `# @role` headings of the
-- editable buffer. Streaming appends and edits recompute folds naturally.

local M = {}

local HEAD = "^# @(%a+)%s*$"

-- Multi-line comment regions fold at level 2:
--   <!-- pitel:tool        long call header, closes on -->
--   <!-- pitel:thinking    model reasoning, closes on -->
--   <!-- pitel:ui          diff display, closes on -->
--   <!-- pitel:error       backend error record, closes on -->
-- Single-line headers (`<!-- pitel:tool {...} -->`, `<!-- pitel:usage … -->`)
-- stay unfolded level-1 content.
local TOOL_HEAD = "^<!%-%- pitel:tool$"
local REGION = "^<!%-%-.*pitel:%a+%s*$"

-- The three view levels, bound to <leader>1..3:
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

function M.expr(lnum)
  local line = vim.fn.getline(lnum)
  if line:match(HEAD) then
    return ">1"
  end
  -- A single-line marker (`<!-- pitel:tool {...} -->`) is content.
  if line:match(REGION) and not line:match("%-%->") then
    return ">2"
  end
  if line:match("^<!%-%- /pitel:") then
    return "1"
  end
  -- Inside a multi-line region (including its --> closer)? Scan up: the
  -- nearest structural line decides. Pretty-printed JSON never starts a
  -- line with `<!--` or `-->`, so the scan is bounded and unambiguous.
  for i = lnum - 1, 1, -1 do
    local s = vim.fn.getline(i)
    if s:match(REGION) and not s:match("%-%->") then
      return "2"
    end
    if s:match(HEAD) or s:match("^<!%-%-") or s:match("^%-%->") then
      return "1"
    end
  end
  return "="
end

function M.text(start, finish)
  start = start or vim.v.foldstart
  finish = finish or vim.v.foldend
  local first = vim.fn.getline(start)

  if first:match(TOOL_HEAD) then
    local name = "?"
    for lnum = start + 1, math.min(finish, start + 12) do
      local n = vim.fn.getline(lnum):match('"name":%s*"([^"]+)"')
      if n then
        name = n
        break
      end
    end
    return string.format("▸ tool: %s (%d lines)", name, finish - start + 1)
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

-- Active fold level, reported in the winbar: the deepest CLOSED fold in
-- the buffer (foldlevel() alone is structural and ignores open state, so
-- measure the level of each closed fold's start line). 0 = fully open,
-- 1 = agent output folded, 2 = tools & thinking folded.
function M.level()
  local lvl = 0
  for lnum = 1, vim.api.nvim_buf_line_count(0) do
    local fs = vim.fn.foldclosed(lnum)
    if fs ~= -1 then
      lvl = math.max(lvl, vim.fn.foldlevel(fs))
      if lvl >= 2 then
        return 2
      end
    end
  end
  return lvl
end

-- Close every level-2 (tool header, thinking, ui, error) fold,
-- leaving message folds untouched. Deterministic: scans for region
-- openers and closes only when that fold isn't already closed (closing
-- an already-closed fold would close its parent).
function M.close_detail_folds(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        for lnum = 1, vim.api.nvim_buf_line_count(buf) do
          local s = vim.fn.getline(lnum)
          if s:match(REGION) and not s:match("%-%->") and vim.fn.foldclosed(lnum) == -1 then
            pcall(vim.cmd, string.format("silent! %dfoldclose", lnum))
          end
        end
      end)
    end
  end
end

-- Open/close state per view, applied with unconditional zM/zR first so a
-- keypress always lands on the same state no matter what was open.
function M.set_view_level(level)
  if level == 1 then
    -- Only user prompts visible; all agent output folded away.
    vim.cmd("silent! normal! zM")
    for lnum = 1, vim.api.nvim_buf_line_count(0) do
      if vim.fn.getline(lnum):match(HEAD) == "user" then
        pcall(vim.cmd, string.format("silent! %dfoldopen!", lnum))
      end
    end
  elseif level == 2 then
    -- Full conversation; tool calls, thinking and display regions folded.
    vim.cmd("silent! normal! zR")
    M.close_detail_folds()
  elseif level == 3 then
    vim.cmd("silent! normal! zR")
  end
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
  M.set_view_level(2)

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
