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
--   # @system      level 3 (folded in views 1 and 2, open in view 3)
-- View 1 = foldlevel 1 (only user open), view 2 = 2 (messages open,
-- tools/thinking/system folded), view 3 = 3 (everything open).
-- The LAST assistant is additionally auto-opened in view 1 (a manual
-- foldopen re-applied after each structural append) so the latest reply
-- stays visible while older replies fold. Levels are kept monotonic (a
-- tool is always exactly one deeper than its enclosing assistant) — a
-- >1 → >3 jump would corrupt Neovim's fold tree and break za/zo. Tool
-- regions and thinking/error are folds one level deeper than their
-- enclosing message; single-line markers (`<!-- yap:usage … -->`) stay
-- unfolded content.
local TOOL_OPEN = "^<!%-%- yap:tool"
local TOOL_CLOSE = "^<!%-%- /yap:tool"
-- Multi-line comment opener (nothing but the word after `yap:`).
local COMMENT_OPEN = "^<!%-%-.*yap:%a+%s*$"

-- The three view levels, bound to <leader>1..3 (the system prompt stays
-- folded in views 1 and 2, open in view 3):
--   1: agent output hidden — only user prompts and the last assistant open
--   2: conversation visible — tool calls, thinking and other display
--      regions folded away
--   3: everything open
M.views = {
  { key = "1", label = "user + last assistant open" },
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
-- >=3 backticks or tildes. Returns (char, run, tail) or nil. Indent is
-- spaces only (CommonMark: a tab advances to the next tab stop, so a
-- tab-indented fence is indented beyond 3 and is not a fence).
local function fence_run(line)
  local ws = line:match("^ *")
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
    local nlvl = role == "user" and 1 or (role == "assistant" and 2 or 3)
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

-- The fold-level string for every line, computed in one forward pass and
-- cached per changedtick: ">N" on a fold opener, "N" inside one, "=" where
-- there is no fold. M.expr is the per-line foldexpr entry point; M.levels
-- is the whole array so callers (fold_start, reapply) can see the `>`
-- markers without re-scanning.
function M.levels(buf)
  buf = (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if not c or c.tick ~= tick then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local levels, region, fence, cret, lvl = {}, nil, nil, nil, nil
    for i, line in ipairs(lines) do
      local lv, nr, nf, nc, nl = classify(line, region, fence, cret, lvl)
      levels[i], region, fence, cret, lvl = lv, nr, nf, nc, nl
    end
    c = { tick = tick, levels = levels }
    cache[buf] = c
  end
  return c.levels
end

function M.expr(lnum)
  return M.levels()[lnum] or "="
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

  local region = first:match("^<!%-%-.*yap:(%a+)")
  if region then
    return string.format("▸ yap: %s (%d lines)", region, finish - start + 1)
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

-- Pinned folds: folds the user opened with <Tab> or the block-navigation
-- keys and wants to KEEP open. The send path also captures native za/zo
-- opens (see reapply_window) and re-opens the union after clearing manual
-- state. Keyed by the fold's start line; sends only append, so a pin's
-- line number stays stable for the lifetime of a session (a user edit
-- above a pin can shift it — the re-apply validates the line is still a
-- fold opener and drops it otherwise).
local pinned = {}
local live_heading = {} -- the last assistant: auto-opened in view 1, folds when the next reply arrives
local prev_openers = {} -- opener lines present before the last re-apply; new folds are excluded from the manual-open capture

--- The set of fold-opener line numbers in a levels array (the ">N" entries).
local function openers(levels)
  local set = {}
  for lnum, lv in ipairs(levels) do
    if lv:sub(1, 1) == ">" then
      set[lnum] = true
    end
  end
  return set
end

--- The line number of the LAST `# @assistant` heading (a level-2 opener),
--- or nil. This is the reply that stays open in view 1; older replies fold.
local function find_live_heading(buf, levels)
  for i = #levels, 1, -1 do
    if levels[i] == ">2"
      and vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] == "# @assistant" then
      return i
    end
  end
  return nil
end

--- Open the auto-open (live) assistant in the current window, if it is
--- currently closed. Views 2/3 keep it open by foldlevel, so this only has
--- an effect in view 1.
local function reopen_live(buf)
  local ln = live_heading[buf]
  if not ln then
    return
  end
  local levels = M.levels(buf)
  if levels[ln] == ">2"
    and vim.fn.getline(ln) == "# @assistant"
    and vim.fn.foldclosed(ln) == ln then
    vim.cmd(("silent! %dfoldopen"):format(ln))
  end
end

function M.level()
  return applied[vim.api.nvim_get_current_buf()] or 3
end

-- The three views are pure 'foldlevel': role-dependent fold levels put
-- user messages at 1, assistant at 2, tool/thinking/system at 3, so
-- foldlevel 1 = view 1, 2 = view 2, 3 = view 3. No manual
-- foldclose anywhere: manual closes combined with expr folds made Neovim
-- re-evaluate every fold on each edit — hundreds of ms per keystroke on a
-- large session. foldlevel alone keeps the same visuals. A real CHANGE of
-- 'foldlevel' resets all manual za toggles to the level's state, so bump
-- first to guarantee the change — a keypress always lands on the same
-- state. A view keypress also clears every pin and manual open (it is an
-- explicit reset).
function M.set_view_level(level)
  local buf = vim.api.nvim_get_current_buf()
  applied[buf] = level
  pinned[buf] = {}
  live_heading[buf] = nil
  local target = ({ 1, 2, 3 })[level] or 3
  vim.wo.foldlevel = 99 -- real change first: resets manual za toggles
  vim.wo.foldlevel = target
  prev_openers[buf] = openers(M.levels(buf))
  -- View 1 keeps the last assistant open so the latest reply is visible;
  -- views 2/3 open it by foldlevel, so only view 1 auto-opens it here.
  if level == 1 then
    live_heading[buf] = find_live_heading(buf, M.levels(buf))
    reopen_live(buf)
  end
end

--- The fold-start line of the fold containing `lnum` (open or closed).
--- Levels aren't depth-monotonic (user 1, assistant 2, tool/system 3,
--- and a `# @user` DROPS back to 1), so a simple upward scan for the
--- nearest `>` marker is wrong after a child fold closes. Instead walk up
--- tracking the minimum level seen: the innermost fold that still encloses
--- `lnum` is the nearest opener whose level is <= that minimum.
local function fold_start(buf, lnum)
  local levels = M.levels(buf)
  local min_level = math.huge
  for i = lnum, 1, -1 do
    local lv = levels[i] or "="
    if lv == "=" then
      break -- pre-heading: nothing encloses it
    end
    local opener = lv:match("^>(%d+)$")
    if opener and tonumber(opener) <= min_level then
      return i
    end
    local n = tonumber((lv:gsub("^>", "")))
    if n and n < min_level then
      min_level = n
    end
  end
  return -1
end

--- Re-apply the applied view to one window: clear every manual open/close
--- (zX re-applies 'foldlevel' without changing its value), then re-open the
--- folds the user had opened:
---   * pinned — folds opened with <Tab> or the block-navigation keys;
---   * manual — folds opened with native za/zo (including za on the system
---              prompt), captured from their open state before zX wipes it;
---   * live   — the last assistant, auto-opened in view 1.
--- `old_live` is the live assistant BEFORE this append: it is excluded from
--- the manual capture so a superseded reply folds instead of being re-opened
--- as if the user had opened it. Folds created by this append are also NOT
--- captured (they are not in prev_openers): Neovim inherits a manual foldopen
--- into child folds, so a freshly-streamed fold would otherwise arrive open.
--- Re-open in line order so a parent opens before its nested children.
--- `:Nfoldopen` opens the fold on line N without moving the cursor, so
--- re-applying during a stream never yanks the user's cursor.
local function reapply_window(w, buf, levels, old_live)
  vim.api.nvim_win_call(w, function()
    local foldlevel = vim.wo.foldlevel
    local prev = prev_openers[buf] or {}
    local manual = {}
    for lnum, lv in ipairs(levels) do
      if lv:sub(1, 1) == ">" then
        local lvl = tonumber(lv:sub(2))
        if lvl and lvl > foldlevel
          and prev[lnum]
          and lnum ~= old_live
          and vim.fn.foldclosed(lnum) == -1 then
          manual[lnum] = true
        end
      end
    end
    vim.cmd("normal! zX")
    for lnum in pairs(pinned[buf] or {}) do
      manual[lnum] = true
    end
    local ln = live_heading[buf]
    if ln and levels[ln] == ">2" and vim.fn.getline(ln) == "# @assistant" then
      manual[ln] = true
    end
    local reopens = {}
    for lnum in pairs(manual) do
      reopens[#reopens + 1] = lnum
    end
    table.sort(reopens)
    for _, lnum in ipairs(reopens) do
      local lv = levels[lnum]
      if lv and lv:sub(1, 1) == ">" and vim.fn.foldclosed(lnum) ~= -1 then
        vim.cmd(("silent! %dfoldopen"):format(lnum))
      end
    end
  end)
end

--- Open a fold persistently (pin it). Used by <Tab> on a closed fold and
--- by the block-navigation keys. Non-exclusive: opening one fold leaves
--- previously opened folds alone.
function M.open(lnum)
  local buf = vim.api.nvim_get_current_buf()
  local start = vim.fn.foldclosed(lnum)
  if start == -1 then
    start = fold_start(buf, lnum)
  end
  if start == -1 then
    return
  end
  pinned[buf] = pinned[buf] or {}
  pinned[buf][start] = true
  if vim.fn.foldclosed(start) ~= -1 then
    vim.api.nvim_win_set_cursor(0, { start, 0 })
    vim.cmd("normal! zo")
  end
end

--- <Tab>: toggle the fold under `lnum`. Opening pins it; closing un-pins
--- it. Pins persist across sends and streaming.
function M.toggle(lnum)
  local buf = vim.api.nvim_get_current_buf()
  local start = vim.fn.foldclosed(lnum)
  if start == -1 then
    start = fold_start(buf, lnum)
  end
  if start == -1 then
    return
  end
  if vim.fn.foldclosed(lnum) == -1 then
    local pin = pinned[buf] or {}
    pin[start] = nil
    vim.api.nvim_win_set_cursor(0, { start, 0 })
    vim.cmd("normal! zc")
  else
    M.open(lnum)
  end
end

--- A line that starts a new fold when it lands in the buffer (the
--- re-apply trigger). `yap:ui` is deliberately excluded: it is content
--- inside a tool region, not a fold of its own, so a streamed ui diff
--- doesn't re-fold the region it belongs to.
local function is_fold_opener(line)
  return line:match(HEAD) ~= nil
    or line:match(TOOL_OPEN) ~= nil
    or line:match("^<!%-%-.*yap:thinking%s*$") ~= nil
    or line:match("^<!%-%-.*yap:error%s*$") ~= nil
end

--- Called by the send/stream path after appending `lines` to a session
--- buffer (never by user edits). If any line opens a new fold, re-apply
--- the view in every window showing the buffer: this clears the manual
--- foldopen that would otherwise leak into the new fold, then restores
--- the folds the user had opened (pins and native za/zo opens) plus the
--- auto-opened last assistant.
function M.after_append(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, l in ipairs(lines or {}) do
    if is_fold_opener(l) then
      local levels = M.levels(buf)
      local old_live = live_heading[buf]
      if vim.tbl_contains(lines, "# @assistant") then
        live_heading[buf] = find_live_heading(buf, levels)
      end
      for _, w in ipairs(vim.fn.win_findbuf(buf)) do
        reapply_window(w, buf, levels, old_live)
      end
      prev_openers[buf] = openers(levels)
      return
    end
  end
end

-- ─── Message navigation ────────────────────────────────────────────────────

local function jump(pattern, backwards)
  return vim.fn.search(pattern, backwards and "bW" or "W")
end

-- Vim-regex equivalents of HEAD for search() (Lua patterns don't apply).
-- No trailing anchor: in Vim regex \s also matches EOL, spilling the
-- match onto the next line.
local VIM_HEAD = [[^# @\a\+]]
local VIM_USER = [[^# @user]]
local VIM_ASSISTANT = [[^# @assistant]]

function M.next_message()
  return jump(VIM_HEAD, false)
end

function M.prev_message()
  return jump(VIM_HEAD, true)
end

function M.next_user_message()
  return jump(VIM_USER, false)
end

function M.prev_user_message()
  return jump(VIM_USER, true)
end

function M.next_assistant_message()
  return jump(VIM_ASSISTANT, false)
end

function M.prev_assistant_message()
  return jump(VIM_ASSISTANT, true)
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
  return jump(VIM_TOOL_OR_THINK, false)
end

function M.prev_tool()
  return jump(VIM_TOOL_OR_THINK, true)
end

function M.next_think()
  return jump(VIM_THINK, false)
end

function M.prev_think()
  return jump(VIM_THINK, true)
end

function M.next_error()
  return jump(VIM_ERROR, false)
end

function M.prev_error()
  return jump(VIM_ERROR, true)
end

-- ─── Buffer setup ──────────────────────────────────────────────────────────

function M.setup_buffer(buf, keys)
  keys = keys or require("harness").config.keymaps
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require'harness.fold'.expr(v:lnum)"
  vim.wo.foldtext = "v:lua.require'harness.fold'.text()"
  vim.wo.foldlevel = 99 -- expr folds start computable; default state applied below
  M.set_view_level(2) -- default: conversation open, tools & thinking folded

  local map = function(lhs, rhs, desc)
    if lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  -- Also as motions: visual (`v]t` selects to the next tool) and
  -- operator-pending (`d]c` deletes to the next thinking block).
  local map_motion = function(lhs, rhs, desc)
    if lhs == "" then
      return
    end
    vim.keymap.set({ "x", "o" }, lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  map(keys.next_message, M.next_message, "Next message")
  map(keys.prev_message, M.prev_message, "Previous message")
  map(keys.next_user, M.next_user_message, "Next user message")
  map(keys.prev_user, M.prev_user_message, "Previous user message")
  map(keys.next_assistant, M.next_assistant_message, "Next assistant message")
  map(keys.prev_assistant, M.prev_assistant_message, "Previous assistant message")
  -- Block navigation (tools, thinking, errors) opens the fold it lands
  -- on — the neogit "OpenOrScroll" feel — pinning it so it stays open.
  -- The bare functions stay pure jumps so they still work as x/o motions
  -- (v]t, d]c).
  local block_jump = function(fn)
    return function()
      if fn() ~= 0 then
        M.open(vim.api.nvim_win_get_cursor(0)[1])
      end
    end
  end
  map(keys.next_tool, block_jump(M.next_tool), "Next tool call or thinking block")
  map(keys.prev_tool, block_jump(M.prev_tool), "Previous tool call or thinking block")
  map(keys.next_think, block_jump(M.next_think), "Next thinking block")
  map(keys.prev_think, block_jump(M.prev_think), "Previous thinking block")
  map(keys.next_error, block_jump(M.next_error), "Next error block")
  map(keys.prev_error, block_jump(M.prev_error), "Previous error block")
  map_motion(keys.next_tool, M.next_tool, "Select to next tool call or thinking block")
  map_motion(keys.prev_tool, M.prev_tool, "Select to previous tool call or thinking block")
  map_motion(keys.next_think, M.next_think, "Select to next thinking block")
  map_motion(keys.prev_think, M.prev_think, "Select to previous thinking block")
  map_motion(keys.next_error, M.next_error, "Select to next error block")
  map_motion(keys.prev_error, M.prev_error, "Select to previous error block")
  local bind_view = function(key, level, desc)
    map(key, function()
      M.set_view_level(level)
    end, desc)
  end
  bind_view(keys.view_1, 1, "Fold all agent messages (user prompts stay open)")
  bind_view(keys.view_2, 2, "Fold all tool calls and thinking blocks")
  bind_view(keys.view_3, 3, "Unfold everything")
  map(keys.toggle_fold, function()
    M.toggle(vim.api.nvim_win_get_cursor(0)[1])
  end, "Toggle fold")
end

-- Exposed for the shared Go/Lua fence conformance test (see
-- tests/fence_cases.json). Not part of the plugin's public API.
M.fence_run = fence_run

return M
