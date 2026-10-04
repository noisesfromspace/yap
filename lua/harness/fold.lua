-- yap folding — flat manual folds over a structural block model.
--
-- The previous implementation used foldmethod=expr with a nested level
-- tree (user=1, assistant=2, tool/thinking/system=3). Nesting is what
-- breaks folding: Vim has no primitive that toggles ONE nested fold
-- (zo/zc/:foldclose act on "the innermost fold", so closing a level-3 tool
-- also closes its level-2 assistant), and an expr fold re-evaluates on
-- every edit, so a manual foldopen leaks into every fold that later
-- materializes at the same/lower level.
--
-- fruit.nvim and codecompanion.nvim solve this with MANUAL folds over
-- FLAT, non-overlapping ranges, rebuilt per view. Each of yap's three
-- views is a flat partition (nothing nests), so a fold is always exactly
-- one range and za/zo/:foldopen/:foldclose target it unambiguously:
--
--   view 1  system prompt + each whole assistant message folded
--   view 2  system prompt + each tool/thinking/error region folded
--   view 3  nothing folded
--
-- Manual folds are per-window and do not run a foldexpr on every edit, so
-- the per-keystroke/per-flush foldexpr re-evaluation cost disappears. The
-- block model is recomputed from the buffer on structural changes and the
-- fold set is reconciled incrementally: only folds whose range actually
-- moved (the streaming tail) are deleted/recreated.

local M = {}

local HEAD = "^# @(%a+)%s*$"

-- A tool region runs from `<!-- yap:tool` (single-line header, or a
-- multi-line header comment whose JSON ends at `-->`) to `<!-- /yap:tool`.
local TOOL_OPEN = "^<!%-%- yap:tool"
local TOOL_CLOSE = "^<!%-%- /yap:tool"
-- Any other multi-line HTML comment (`<!-- yap:thinking`, `<!-- yap:error`,
-- legacy `<!-- yap:ui`) is a fold of its own and closes on a bare `-->`.
-- Single-line markers (`<!-- yap:usage … -->`) never match: they stay content.
local COMMENT_OPEN = "^<!%-%-.*yap:%a+%s*$"

-- The three view levels, bound to <leader>1..3 (the system prompt stays
-- folded in views 1 and 2, open in view 3):
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

-- ─── block model ───────────────────────────────────────────────────────────

-- One O(n) forward pass over the buffer produces the structural blocks the
-- three views fold. Fences and multi-line HTML comments are tracked so a
-- fake `# @user` inside a fenced tool result, or a `-->` inside a fence,
-- can't split the structure. This mirrors the old classify() state machine
-- but emits block ranges instead of per-line level strings.
--
--   headings = { {role="system"|"user"|"assistant", line}, … }  (in order)
--   details  = { {kind="tool"|"thinking"|"error"|…, start, finish}, … }
--              finish is nil while a region is still open (streaming).
local model_cache = {} -- buf -> { tick, parse }

local function parse(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local cached = model_cache[buf]
  if cached and cached.tick == tick then
    return cached.parse
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local headings, details = {}, {}
  local region, fence, comment = nil, nil, nil

  for i, line in ipairs(lines) do
    if fence then
      local c, n, tail = fence_run(line)
      if c == fence.char and n >= fence.n and tail:match("^%s*$") then
        fence = nil
      end
    elseif comment then
      -- Inside a multi-line HTML comment: raw text until a bare `-->`
      -- (a ``` inside a comment is NOT a fence).
      if line:match("^%-%->%s*$") then
        if comment.detail then
          comment.detail.finish = i
        end
        comment = nil
      end
    else
      local c, n = fence_run(line)
      if c then
        fence = { char = c, n = n }
      elseif line:match(HEAD) then
        headings[#headings + 1] = { role = line:match(HEAD), line = i }
        region = nil
      elseif line:match(TOOL_OPEN) then
        local d = { kind = "tool", start = i }
        details[#details + 1] = d
        region = "tool"
      elseif line:match(COMMENT_OPEN) and not line:match("%-%->") then
        if region == "tool" then
          -- A legacy yap:ui subsection inside a tool region is content of
          -- the region fold, not a fold of its own.
          comment = { kind = "tool_inner" }
        else
          local kind = line:match("yap:(%a+)") or "comment"
          local d = { kind = kind, start = i }
          details[#details + 1] = d
          comment = { kind = kind, detail = d }
        end
      elseif line:match(TOOL_CLOSE) then
        local d = details[#details]
        if region == "tool" and d and d.kind == "tool" and not d.finish then
          d.finish = i
        end
        region = nil
      end
      -- else: plain content line
    end
  end

  local p = { headings = headings, details = details, count = #lines }
  model_cache[buf] = { tick = tick, parse = p }
  return p
end

-- ─── per-buffer state ──────────────────────────────────────────────────────

local view = {} -- buf -> applied view level (1..3)
local opened = {} -- buf -> { [fold_start] = true } — user-pinned folds
local blocks = {} -- buf -> { {start, finish}, … } — last intended fold set
local created = {} -- buf -> { [win] = { [fold_start] = finish } } — folds on screen

-- The flat, non-overlapping fold set for a view. finish for a block ends at
-- the next heading minus one, or at its closer, or at EOF while it streams.
local function intended(buf, p)
  local level = view[buf] or 2
  local out = {}
  if level == 1 then
    -- system + each whole assistant message
    for idx, h in ipairs(p.headings) do
      if h.role == "system" or h.role == "assistant" then
        local nxt = p.headings[idx + 1]
        out[#out + 1] = { start = h.line, finish = nxt and (nxt.line - 1) or p.count }
      end
    end
  elseif level == 2 then
    -- system + each tool/thinking/error region
    for idx, h in ipairs(p.headings) do
      if h.role == "system" then
        local nxt = p.headings[idx + 1]
        out[#out + 1] = { start = h.line, finish = nxt and (nxt.line - 1) or p.count }
        break
      end
    end
    for _, d in ipairs(p.details) do
      out[#out + 1] = { start = d.start, finish = d.finish or p.count }
    end
  end
  return out
end

local function same_blocks(a, b)
  if a == b then
    return true
  end
  if not a or not b or #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i].start ~= b[i].start or a[i].finish ~= b[i].finish then
      return false
    end
  end
  return true
end

local function block_at(buf, lnum)
  local list = intended(buf, parse(buf))
  for _, b in ipairs(list) do
    if b.finish > b.start and lnum >= b.start and lnum <= b.finish then
      return b
    end
  end
  return nil
end

-- ─── low-level fold ops (act on the current window) ────────────────────────

-- Manual folds are per-window, so every op below runs inside
-- nvim_win_call for the window being reconciled. A single-line range is
-- skipped: `:N,Nfold` does not create a closed fold, so an empty message
-- or a just-arrived opener (nothing to hide) stays unfolded.

local function fold_create(start, finish)
  vim.cmd(string.format("%d,%dfold", start, finish))
end

local function fold_open(start)
  if vim.fn.foldlevel(start) > 0 then
    vim.cmd(string.format("%dfoldopen", start))
  end
end

local function fold_close(start)
  if vim.fn.foldlevel(start) > 0 then
    vim.cmd(string.format("%dfoldclose", start))
  end
end

local function fold_delete(start)
  if vim.fn.foldlevel(start) > 0 then
    vim.api.nvim_win_set_cursor(0, { start, 0 })
    vim.cmd("normal! zd")
  end
end

local function with_view(fn)
  local v = vim.fn.winsaveview()
  fn()
  vim.fn.winrestview(v)
end

-- ─── reconcile ─────────────────────────────────────────────────────────────

--- Apply the intended fold set to one window. Only folds that changed are
--- touched: removed folds are deleted, new folds created (closed), and a
--- fold whose finish moved is recreated. Native za/zo on a fold whose range
--- did NOT move is left untouched (so it persists); a fold being recreated
--- closes again unless it is explicitly pinned (M.open/<Tab>/navigation).
local function apply_window(win, buf, list, pins, full)
  vim.api.nvim_win_call(win, function()
    local v = vim.fn.winsaveview()
    created[buf] = created[buf] or {}
    local per_win = created[buf][win] or {}
    if full then
      vim.cmd("normal! zE")
      per_win = {}
    end

    local by_start = {}
    for _, b in ipairs(list) do
      by_start[b.start] = b
    end

    -- 1. delete folds whose block vanished
    for start in pairs(per_win) do
      if not by_start[start] then
        fold_delete(start)
      end
    end

    -- 2. create new / recreate moved folds
    local next_win = {}
    for _, b in ipairs(list) do
      local prev = per_win[b.start]
      if prev == nil then
        if b.finish > b.start then
          fold_create(b.start, b.finish)
        end
        next_win[b.start] = b.finish
      elseif prev ~= b.finish then
        -- Recreate. We do NOT read foldclosed() here to preserve native
        -- za/zo opens: after an edit Neovim lazily reports a closed fold's
        -- state as open (fc=-1), so capture would mis-pin folds the user
        -- never opened. Native za/zo on a fold whose range didn't move is
        -- left untouched anyway; only explicit <Tab>/nav pins (opened table)
        -- survive a recreate.
        fold_delete(b.start)
        if b.finish > b.start then
          fold_create(b.start, b.finish)
        end
        next_win[b.start] = b.finish
      else
        next_win[b.start] = prev
      end
    end

    -- 3. re-open user-pinned folds (idempotent: :Nfoldopen on an open fold
    --    is a no-op)
    for start in pairs(pins) do
      if by_start[start] then
        fold_open(start)
      end
    end

    created[buf][win] = next_win
    vim.fn.winrestview(v)
  end)
end

--- Reconcile every window showing `buf` to its view's fold set. `full` does
--- a from-scratch rebuild (view change); otherwise only changed folds are
--- touched and identical fold sets are a no-op.
function M.reconcile(buf, full)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local p = parse(buf)
  local list = intended(buf, p)
  if not full and same_blocks(list, blocks[buf]) then
    return
  end
  blocks[buf] = list
  local pins = opened[buf] or {}
  opened[buf] = pins
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      apply_window(win, buf, list, pins, full)
    end
  end
end

function M.level()
  return view[vim.api.nvim_get_current_buf()] or 3
end

--- Set the view level and rebuild the fold set from scratch. This is an
--- explicit reset: it clears every user-pinned fold (a view keypress always
--- lands on the view's default state).
function M.set_view_level(level)
  local buf = vim.api.nvim_get_current_buf()
  view[buf] = level
  opened[buf] = {}
  blocks[buf] = nil
  M.reconcile(buf, true)
end

--- Open a fold persistently (pin it). Non-exclusive: opening one fold leaves
--- previously opened folds alone. Used by <Tab> on a closed fold and by the
--- block-navigation keys.
function M.open(lnum)
  local buf = vim.api.nvim_get_current_buf()
  local b = block_at(buf, lnum)
  if not b then
    return
  end
  opened[buf] = opened[buf] or {}
  opened[buf][b.start] = true
  with_view(function()
    fold_open(b.start)
  end)
end

--- <Tab>: toggle the fold under `lnum`. Opening records it as user-opened;
--- closing forgets it. User opens persist across sends and streaming.
function M.toggle(lnum)
  local buf = vim.api.nvim_get_current_buf()
  local b = block_at(buf, lnum)
  if not b then
    return
  end
  if vim.fn.foldlevel(b.start) > 0 and vim.fn.foldclosed(b.start) == -1 then
    opened[buf] = opened[buf] or {}
    opened[buf][b.start] = nil
    with_view(function()
      fold_close(b.start)
    end)
  else
    M.open(lnum)
  end
end

--- Called by the send/stream path after appending lines to a session buffer.
--- Re-parses the buffer and reconciles only the folds whose ranges changed.
function M.after_append(buf, _)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  M.reconcile(buf, false)
end

-- ─── foldtext ──────────────────────────────────────────────────────────────

-- Foldtext is re-evaluated for every visible closed fold on every screen
-- draw, and each evaluation crosses into VimL plus string formatting. The
-- text depends only on the buffer content, which changes only with the
-- changedtick, so cache the rendered string per fold start line: after the
-- first paint of a given tick, a redraw is a table lookup.
local text_cache = {} -- buf -> { tick, by_start = { [foldstart] = { finish, text } } }

function M.text(start, finish)
  start = start or vim.v.foldstart
  finish = finish or vim.v.foldend
  local buf = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = text_cache[buf]
  if not c or c.tick ~= tick then
    c = { tick = tick, by_start = {} }
    text_cache[buf] = c
  end
  local e = c.by_start[start]
  if e and e.finish == finish then
    return e.text
  end

  local first = vim.fn.getline(start)
  local text

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
    text = string.format("▸ tool: %s (%d lines)", name or "?", finish - start + 1)
  else
    local region = first:match("^<!%-%-.*yap:(%a+)")
    if region then
      text = string.format("▸ yap: %s (%d lines)", region, finish - start + 1)
    else
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
      text = string.format("▸ @%s │ %s (%d lines)", role, preview, finish - start + 1)
    end
  end

  c.by_start[start] = { finish = finish, text = text }
  return text
end

--- Drop a buffer's per-buffer state (BufWipeout). The tick checks already
--- invalidate on buffer-number reuse; this releases the strings sooner.
function M.clear_text(buf)
  text_cache[buf] = nil
  model_cache[buf] = nil
  view[buf] = nil
  opened[buf] = nil
  blocks[buf] = nil
  created[buf] = nil
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
  vim.wo.foldmethod = "manual"
  vim.wo.foldlevel = 0 -- keep :fold closed; explicit foldopen overrides
  vim.wo.foldtext = "v:lua.require'harness.fold'.text()"
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
-- tests/fence_cases.json) and the perf profiler. Not part of the public API.
M.fence_run = fence_run
M.parse = parse

return M
