-- yap folding — ported from fruit.nvim's view.lua, adapted to yap's
-- live markdown buffer: instead of re-rendering a JSONL session into a
-- read-only view, folds sit directly on the `# @role` headings of the
-- editable buffer. Streaming appends and edits recompute folds naturally.

local M = {}

local HEAD = "^# @(%a+)%s*$"

-- Fold levels are role-dependent so the three views are pure 'foldlevel'
-- (no manual foldclose: manual closes plus expr folds made Neovim
-- re-evaluate every fold on each edit — the per-keystroke lag on large
-- sessions):
--   # @user        level 1
--   # @assistant   level 2
--   tool region    level 3 (one deeper than its message)
--   thinking/error level 3 (same)
--   # @system      level 4 (folded in every view until opened with za)
-- View 1 = foldlevel 1 (only user open), view 2 = 2 (messages open,
-- tools/thinking folded), view 3 = 3 (everything but the system prompt).
-- Tool regions and thinking/error are folds one level deeper than their
-- enclosing message; single-line markers (`<!-- yap:usage … -->`) stay
-- unfolded content.
local TOOL_OPEN = "^<!%-%- yap:tool"
local TOOL_CLOSE = "^<!%-%- /yap:tool"
-- Multi-line comment opener (nothing but the word after `yap:`).
local COMMENT_OPEN = "^<!%-%-.*yap:%a+%s*$"

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

-- Fold levels are computed in ONE forward pass and cached per
-- changedtick. foldexpr runs per displayed line, and the old
-- implementation scanned UPWARD line by line for each call — O(region²)
-- for a tall tool result (a 2000-line bash output made one fold
-- recompute take ~450ms). A tiny state machine over the line types is
-- O(n) total; the cache is rebuilt only when the buffer changes.
--
-- The state machine carries the numeric fold level plus the structural
-- region. region is nil (pre-heading), "top" (message) or "tool" (inside
-- a yap:tool region). cret is { region, lvl } — where a multi-line HTML
-- comment returns after its `-->`: a thinking/error comment returns to
-- "top", a legacy `<!-- yap:ui` subsection returns to "tool". A bare
-- `-->` inside a tool region but OUTSIDE a comment closes the multi-line
-- tool header; only `<!-- /yap:tool` ends a tool region.
--
-- fence is nil or { char, n } for an open fenced code block. Tool
-- results are fenced, and their content is arbitrary (a bash `cat` of a
-- yap session contains `# @user` lines): inside a fence EVERY line is
-- literal — no heading, marker or `-->` interpretation — or the fold
-- structure splits at fake headings inside the result.
local cache = {} -- buf -> { tick, levels = { lnum -> levelstr } }

-- fence_run: a fence opener/closer — <=3 spaces indent then a run of
-- >=3 backticks or tildes. Returns (char, run, tail) or nil.
local function fence_run(line)
  local ws = line:match("^%s*")
  if #ws > 3 then
    return nil
  end
  local rest = line:sub(#ws + 1)
  local c = rest:sub(1, 1)
  if c ~= "`" and c ~= "~" then
    return nil
  end
  local n = 0
  while rest:sub(n + 1, n + 1) == c do
    n = n + 1
  end
  if n < 3 then
    return nil
  end
  return c, n, rest:sub(n + 1)
end

local function classify(line, region, fence, cret, lvl)
  local cur = lvl and tostring(lvl) or "="
  if fence then
    -- Inside a fence: literal until a matching closer (same char, at
    -- least as long, then only spaces).
    local c, n, tail = fence_run(line)
    if c == fence.char and n >= fence.n and tail:match("^%s*$") then
      return cur, region, nil, cret, lvl
    end
    return cur, region, fence, cret, lvl
  end
  if cret then
    -- Inside a multi-line HTML comment: raw text until a bare `-->`
    -- (a ``` inside a comment is NOT a fence). The closer is the fold's
    -- last line; the state after it returns to the enclosing region.
    if line:match("^%-%->%s*$") then
      return cur, cret.region, nil, nil, cret.lvl
    end
    return cur, region, fence, cret, lvl
  end
  local c, n = fence_run(line)
  if c then
    return cur, region, { char = c, n = n }, cret, lvl
  end
  if line:match(HEAD) then
    local role = line:match(HEAD)
    local nlvl = role == "user" and 1 or (role == "assistant" and 2 or 4)
    return ">" .. nlvl, "top", nil, cret, nlvl
  elseif line:match(TOOL_OPEN) then
    local nlvl = (lvl or 0) + 1
    return ">" .. nlvl, "tool", nil, cret, nlvl -- both header forms start the region fold
  elseif line:match(COMMENT_OPEN) and not line:match("%-%->") then
    -- A comment opener inside a tool region (legacy yap:ui) is content
    -- of the region fold, not a fold of its own.
    if region == "tool" then
      return cur, "tool", nil, { region = "tool", lvl = lvl }, lvl
    end
    local nlvl = (lvl or 0) + 1
    return ">" .. nlvl, "top", nil, { region = "top", lvl = lvl }, nlvl
  elseif line:match(TOOL_CLOSE) then
    return cur, "top", nil, cret, (lvl or 1) - 1 -- closer is the region fold's last line
  else
    return cur, region, fence, cret, lvl
  end
end

function M.expr(lnum)
  local buf = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if not c or c.tick ~= tick then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local levels, region, fence, cret, lvl = {}, nil, nil, nil, nil
    local last_asst = 0
    for i, line in ipairs(lines) do
      local lv, nr, nf, nc, nl = classify(line, region, fence, cret, lvl)
      levels[i], region, fence, cret, lvl = lv, nr, nf, nc, nl
      if line:match("^# @assistant%s*$") then
        last_asst = i
      end
    end
    -- A reply that streamed into this buffer stays open in view 1 (level 1)
    -- so the user sees it arrive; older replies stay folded (level 2). The
    -- send path sets b:yap_live, so a freshly opened session folds all
    -- agent output until the first send. Nested tool/thinking regions stay
    -- at level 3 and keep folding in views 1/2.
    if vim.b[buf].yap_live and last_asst > 0 then
      for i = last_asst, #levels do
        local l = levels[i]
        if i == last_asst then
          levels[i] = ">1"
        elseif l == "2" then
          levels[i] = "1"
        elseif l == ">1" or l == ">4" then
          break -- next message heading: the live block ends here
        end
      end
    end
    c = { tick = tick, levels = levels }
    cache[buf] = c
  end
  return c.levels[lnum] or "="
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

  local region = first:match("^<!%-%-.*(yap:%a+)")
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

-- The three views are pure 'foldlevel': role-dependent fold levels put
-- user messages at 1, assistant at 2, tool/thinking at 3 and the system
-- prompt at 4, so foldlevel 1 = view 1, 2 = view 2, 3 = view 3. No manual
-- foldclose anywhere: manual closes combined with expr folds made Neovim
-- re-evaluate every fold on each edit — hundreds of ms per keystroke on a
-- large session. foldlevel alone keeps the same visuals. A real CHANGE of
-- 'foldlevel' resets all manual za toggles to the level's state, so bump
-- first to guarantee the change — a keypress always lands on the same
-- state. Between keypresses NOTHING touches fold state: new folds adopt
-- 'foldlevel' (streamed tool regions appear folded in views 1/2, open in
-- 3), manual za persists, typing changes nothing.
function M.set_view_level(level)
  applied[vim.api.nvim_get_current_buf()] = level
  local target = ({ 1, 2, 3 })[level] or 3
  vim.wo.foldlevel = 99 -- real change first: resets manual za toggles
  vim.wo.foldlevel = target
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

-- Block-region navigation: the three display blocks worth hopping between
-- when reviewing a long reply. Vim-regex twins of the Lua patterns above
-- (Lua patterns don't apply to vim.fn.search).
local VIM_THINK = [[^<!-- yap:thinking]]
local VIM_ERROR = [[^<!-- yap:error]]
-- `]t`/`[t` hop between tool calls and thinking: both are machine blocks
-- worth reviewing, and a tool call is usually preceded by thinking. `]c`
-- remains thinking-only.
local VIM_TOOL_OR_THINK = [[^<!-- yap:\(tool\|thinking\)]]

function M.next_tool()
  jump(VIM_TOOL_OR_THINK, false)
end

function M.prev_tool()
  jump(VIM_TOOL_OR_THINK, true)
end

function M.next_think()
  jump(VIM_THINK, false)
end

function M.prev_think()
  jump(VIM_THINK, true)
end

function M.next_error()
  jump(VIM_ERROR, false)
end

function M.prev_error()
  jump(VIM_ERROR, true)
end

-- ─── Buffer setup ──────────────────────────────────────────────────────────

function M.setup_buffer(buf)
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require'harness.fold'.expr(v:lnum)"
  vim.wo.foldtext = "v:lua.require'harness.fold'.text()"
  vim.wo.foldlevel = 99 -- expr folds start computable; default state applied below
  M.set_view_level(2) -- default: conversation open, tools & thinking folded

  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  -- Also as motions: visual (`v]t` selects to the next tool) and
  -- operator-pending (`d]c` deletes to the next thinking block).
  local map_motion = function(lhs, rhs, desc)
    vim.keymap.set({ "x", "o" }, lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  map("]m", M.next_message, "Next message")
  map("[m", M.prev_message, "Previous message")
  map("]u", M.next_user_message, "Next user message")
  map("[u", M.prev_user_message, "Previous user message")
  map("]a", M.next_assistant_message, "Next assistant message")
  map("[a", M.prev_assistant_message, "Previous assistant message")
  map("]t", M.next_tool, "Next tool call or thinking block")
  map("[t", M.prev_tool, "Previous tool call or thinking block")
  map("]c", M.next_think, "Next thinking block")
  map("[c", M.prev_think, "Previous thinking block")
  map("]e", M.next_error, "Next error block")
  map("[e", M.prev_error, "Previous error block")
  map_motion("]t", M.next_tool, "Select to next tool call or thinking block")
  map_motion("[t", M.prev_tool, "Select to previous tool call or thinking block")
  map_motion("]c", M.next_think, "Select to next thinking block")
  map_motion("[c", M.prev_think, "Select to previous thinking block")
  map_motion("]e", M.next_error, "Select to next error block")
  map_motion("[e", M.prev_error, "Select to previous error block")
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
