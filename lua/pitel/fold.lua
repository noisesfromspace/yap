-- pitel folding — ported from fruit.nvim's view.lua, adapted to pitel's
-- live markdown buffer: instead of re-rendering a JSONL session into a
-- read-only view, folds sit directly on the `# @role` headings of the
-- editable buffer. Streaming appends and edits recompute folds naturally.

local M = {}

local HEAD = "^# @(%a+)%s*$"

-- Multi-line pitel:tool headers (long calls: write/edit) open a level-2
-- fold; the closing `-->` line is part of the fold. Single-line headers
-- stay unfolded level-1 content.
local TOOL_HEAD = "^<!%-%- pitel:tool$"

-- The four view levels, bound to <leader>1..4 (same keys as fruit).
-- Level 1 (outline) is fruit's default fold state: only user prompts and
-- the last block open. roles = which heading roles stay open; nil = all.
M.views = {
  { key = "1", label = "outline" },
  { key = "2", label = "user",         roles = { "user" } },
  { key = "3", label = "conversation", roles = { "user", "assistant" } },
  { key = "4", label = "full",         roles = nil },
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
  if line:match(TOOL_HEAD) then
    return ">2"
  end
  -- Inside a multi-line tool header (including its --> closer)? Scan up:
  -- the nearest structural line decides. Pretty-printed JSON never starts
  -- a line with `<!--` or `-->`, so the scan is bounded and unambiguous.
  for i = lnum - 1, 1, -1 do
    local s = vim.fn.getline(i)
    if s:match(TOOL_HEAD) then
      return "2"
    end
    if s:match(HEAD) or s:match("^<!%-%-") then
      break
    end
    if s:match("^%-%->") then
      return "1" -- follows a closed header: block content, not fold
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
    return string.format("▸ tool: %s  (%d lines)", name, finish - start + 1)
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

  return string.format("▸ @%s │ %s  (%d lines)", role, preview, finish - start + 1)
end

-- ─── Default fold state (ported from fruit.nvim) ──────────────────────────

-- Tool-argument folds stay closed in every message-structure view: the
-- pitel:ui diff is the visual record, the JSON is inspectable with za.
-- Also called during streaming: newly appended folds default to open.
function M.close_tool_folds(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        for lnum = 1, vim.api.nvim_buf_line_count(buf) do
          -- foldclose on an already-closed fold closes its PARENT, so
          -- only close when the line is not inside any closed fold.
          if vim.fn.getline(lnum):match(TOOL_HEAD) and vim.fn.foldclosed(lnum) == -1 then
            pcall(vim.cmd, string.format("silent! %dfoldclose", lnum))
          end
        end
      end)
    end
  end
end

-- Fruit's closing logic: fold everything except user prompts (the visible
-- outline) and the last block (newest activity stays visible).
function M.apply_default_folds(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.cmd("silent! normal! zM")
        local last_head = nil
        for lnum = 1, vim.api.nvim_buf_line_count(buf) do
          local role = vim.fn.getline(lnum):match(HEAD)
          if role then
            last_head = lnum
            if role == "user" then
              pcall(vim.cmd, string.format("silent! %dfoldopen!", lnum))
            end
          end
        end
        if last_head then
          pcall(vim.cmd, string.format("silent! %dfoldopen!", last_head))
        end
        M.close_tool_folds(buf)
      end)
    end
  end
end

-- ─── View levels ───────────────────────────────────────────────────────────

local function open_roles(roles)
  vim.cmd("silent! normal! zM")
  for lnum = 1, vim.api.nvim_buf_line_count(0) do
    local role = vim.fn.getline(lnum):match(HEAD)
    if role and vim.tbl_contains(roles, role) then
      pcall(vim.cmd, string.format("silent! %dfoldopen!", lnum))
    end
  end
  M.close_tool_folds()
end

function M.set_view_level(level)
  local view = M.views[level]
  if not view then
    return
  end
  if level == 1 then
    M.apply_default_folds()
  elseif view.roles then
    open_roles(view.roles)
  else
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
  vim.wo.foldexpr = "v:lua.require'pitel.fold'.expr(v:lnum)"
  vim.wo.foldtext = "v:lua.require'pitel.fold'.text()"
  vim.wo.foldlevel = 99 -- expr folds start computable; default state applied below
  M.apply_default_folds(buf)

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
  bind_view("<leader>1", 1, "View: outline")
  bind_view("<leader>2", 2, "View: user only")
  bind_view("<leader>3", 3, "View: conversation")
  bind_view("<leader>4", 4, "View: full expanded")
  map("<Tab>", "za", "Toggle fold")
end

return M
