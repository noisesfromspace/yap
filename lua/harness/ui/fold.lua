-- Yap folds are a projection of structural units, not their identity.
-- Extmarks anchor folds through edits/undo. Each window owns its view and
-- explicit open/closed choices. Native folds are observed before replacing
-- changed ranges, so Tab, za/zo/zc and Ex fold commands have the same meaning.
-- Views remain flat: messages in view 1, regions in view 2, none in view 3.

local M = {}

local structure = require("harness.model.structure")
local view = require("harness.ui.view")
local HEAD = structure.HEAD
local TOOL_OPEN = structure.TOOL_OPEN
local parse = structure.parse
local extend = structure.extend
local mark_changed = structure.mark_changed

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

-- ─── identity, intent and projection ───────────────────────────────────────

local anchors = vim.api.nvim_create_namespace("yap.fold.regions")
local sessions = {} -- buf -> fold identities and per-window projections
local group = vim.api.nvim_create_augroup("YapFolds", { clear = true })

-- User edits/undo reconcile on a pause, not per keystroke: extmarks and
-- native manual folds already track the edit, so the full O(n) reparse can
-- wait until typing stops. Stream appends are unaffected (they reconcile
-- synchronously via after_append before yielding).
local IDLE_RECONCILE_MS = 150

-- All live fold anchors in one batch: id -> 1-based row. Replacing a
-- per-fold get_extmark_by_id walk with a single get_extmarks call keeps
-- capture() and apply()'s drift check off the O(folds) C round-trip path.
local function extmark_rows(buf)
  local rows = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, anchors, 0, -1, {})) do
    rows[mark[1]] = mark[2] + 1
  end
  return rows
end

-- The installed fold containing the last line: the one with the greatest
-- start line not past the tail. A tail append can only split/remove that
-- one fold, so its intent is the only one that must be captured before the
-- edit (a one-line manual fold is removed when its line is split).
local function tail_installed(w, lastline)
  local best_id, best_start
  for id, rec in pairs(w.installed) do
    if rec.start <= lastline and (best_start == nil or rec.start > best_start) then
      best_id, best_start = id, rec.start
    end
  end
  return best_id, best_start
end

local function capture_one(buf, win, w, id, start)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  vim.api.nvim_win_call(win, function()
    if not vim.wo.foldenable then
      return
    end
    if vim.fn.foldlevel(start) > 0 then
      local closed = vim.fn.foldclosed(start)
      if closed == -1 or closed == start then
        w.intent[id] = closed == -1
      end
    end
  end)
end

-- Only actual native folds are observed. Missing/deleted folds are not
-- mistaken for user opens, and disabling folding does not pin everything.
-- With manual folds there is no foldexpr/lazy recomputation to confuse this
-- observation. on_lines sees both native ranges and extmarks AFTER shifting.
local function capture(buf, win, w)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  local rows = extmark_rows(buf)
  vim.api.nvim_win_call(win, function()
    if not vim.wo.foldenable then
      return
    end
    for id in pairs(w.installed) do
      local row = rows[id]
      if row and vim.fn.foldlevel(row) > 0 then
        local closed = vim.fn.foldclosed(row)
        if closed == -1 or closed == row then
          w.intent[id] = closed == -1
        end
      end
    end
  end)
end

local function state(buf)
  local s = sessions[buf]
  if s then
    return s
  end
  s = { records = {}, windows = {}, default_view = 2, streaming = false }
  sessions[buf] = s
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(...)
      -- firstline (0-based index of the first changed OLD line) lets
      -- structure tell a pure tail append from a middle edit. Neovim 0.13
      -- passes ("lines", bufnr, changedtick, firstline, …); earlier versions
      -- pass (bufnr, changedtick, firstline, …).
      local firstline
      if select("#", ...) >= 4 and type(select(1, ...)) == "string" then
        firstline = select(4, ...)
      elseif select("#", ...) >= 3 then
        firstline = select(3, ...)
      end
      mark_changed(buf, firstline)
      -- Native fold intents are observed by capture() right before a rebuild
      -- in apply(), so walking every installed fold on every keystroke here
      -- is pure O(folds) overhead — the dominant typing cost on long
      -- sessions. Document mutations still capture ahead of their edit in
      -- before_change, where a split one-line fold can still be observed.
      -- Arbitrary user edits/undo need reconciliation as well as streaming.
      -- Stream writes call after_append synchronously, before yielding;
      -- this debounced callback is the fallback for other buffer mutations.
      if s.timer then
        s.timer:stop()
        s.timer:close()
        s.timer = nil
      end
      s.timer = vim.defer_fn(function()
        s.timer = nil
        if
          sessions[buf] == s
          and vim.api.nvim_buf_is_valid(buf)
          and s.projected_tick ~= vim.api.nvim_buf_get_changedtick(buf)
        then
          M.reconcile(buf)
        end
      end, IDLE_RECONCILE_MS)
    end,
    on_reload = function()
      structure.clear(buf)
      for _, w in pairs(s.windows) do
        w.rebuild = true
      end
      vim.schedule(function()
        if sessions[buf] == s then
          M.reconcile(buf)
        end
      end)
    end,
    on_detach = function()
      -- An explicit unload discards native folds/extmarks; reinitialize on
      -- load. Merely hiding a session does not detach or discard any state.
      s.detached = true
      if s.timer then
        s.timer:stop()
        s.timer:close()
        s.timer = nil
      end
      structure.clear(buf)
    end,
  })
  return s
end

local function window(s, win)
  if not s.windows[win] then
    s.windows[win] = { view = s.default_view, intent = {}, installed = {}, rebuild = true }
  end
  return s.windows[win]
end

-- A deleted anchor is retained for undo, but never matched while invalid.
-- Copies at the same line get new identities; a pin cannot transfer to them.
local function identify(buf, s, p)
  if s.tick == vim.api.nvim_buf_get_changedtick(buf) then
    return s.folds
  end
  -- One batched nvim_buf_get_extmarks replaces a per-record
  -- get_extmark_by_id walk: s.records holds every fold id ever created
  -- (including invalidated ones retained for undo), so querying one at a time
  -- is O(records) C round-trips per reconcile. The batch returns only live
  -- marks in one call; s.records stays the id→kind map and must not be
  -- pruned, or an undo_restore'd anchor would lose its identity/intent.
  local at = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, anchors, 0, -1, {})) do
    local kind = s.records[mark[1]]
    if kind then
      local row = mark[2] + 1
      at[row] = at[row] or {}
      at[row][kind] = mark[1]
    end
  end
  local all = {}
  local function add(kind, start, finish)
    local id = at[start] and at[start][kind]
    if not id then
      id = vim.api.nvim_buf_set_extmark(buf, anchors, start - 1, 0, {
        end_row = start - 1,
        end_col = 1,
        right_gravity = true,
        end_right_gravity = false,
        invalidate = true,
        undo_restore = true,
      })
      s.records[id] = kind
    end
    all[#all + 1] = { id = id, kind = kind, start = start, finish = finish }
  end
  if p.frontmatter then
    add("message:frontmatter", 1, p.frontmatter)
  end
  -- headings and regions are each already sorted by line; merge them instead
  -- of a table.sort (O(n) rather than O(n log n)).
  local h, r = p.headings, p.regions
  local hi, ri = 1, 1
  while hi <= #h or ri <= #r do
    if ri > #r or (hi <= #h and h[hi].line <= r[ri].start) then
      add("message:" .. h[hi].role, h[hi].line, h[hi + 1] and h[hi + 1].line - 1 or p.count)
      hi = hi + 1
    else
      add("region:" .. r[ri].kind, r[ri].start, r[ri].fold_finish or r[ri].finish or p.count)
      ri = ri + 1
    end
  end
  s.folds, s.tick = all, vim.api.nvim_buf_get_changedtick(buf)
  return all
end

local function intended(all, level)
  local list, finish = {}, 0
  for _, b in ipairs(all) do
    local include = level ~= 3 and (b.kind == "message:system" or b.kind == "message:frontmatter")
      or level == 1 and b.kind == "message:assistant"
      or level == 2 and b.kind:sub(1, 7) == "region:"
    -- System material may itself contain regions. Never install overlapping
    -- folds: the enclosing system range already hides that material.
    if include and b.start > finish then
      list[#list + 1], finish = b, b.finish
    end
  end
  return list
end

local function options()
  vim.wo.foldmethod = "manual"
  vim.wo.foldminlines = 0 -- even the first complete opener arrives folded
  vim.wo.foldtext = "v:lua.require'harness.ui.fold'.text()"
end

local function apply(buf, win, w, list)
  vim.api.nvim_win_call(win, function()
    local saved = vim.fn.winsaveview()
    options()
    local wanted = {}
    for _, b in ipairs(list) do
      wanted[b.id] = b
    end
    -- A full rebuild is needed when the window was (re)entered, the view was
    -- reset, an anchor moved (an edit above shifted its line numbers), or a
    -- fold's range drifted — a stream append grows a fold's finish, or
    -- splits the buffer's last line so Neovim shrinks the native fold by one
    -- (the foldlevel of the recorded finish drops to 0). None of the stream
    -- appends move the cursor, so this rebuild stays cursor-free.
    local rebuild = w.rebuild or w.reset or w.restore
    if not rebuild then
      local rows = extmark_rows(buf)
      for id, old in pairs(w.installed) do
        local b = wanted[id]
        if
          rows[id] ~= old.start
          or vim.fn.foldlevel(old.start) ~= 1
          or not b
          or b.start ~= old.start
          or b.finish ~= old.finish
          or vim.fn.foldlevel(b.finish) < 1
        then
          rebuild = true
          break
        end
      end
    end
    if rebuild then
      -- Surviving native opens/closes may have changed since the last edit.
      -- New windows and explicit view resets deliberately have no old set.
      if not w.reset and not w.restore then
        capture(buf, win, w)
      end
      -- Rebuild cursor-free: zE wipes every fold without touching the cursor
      -- or viewport, then each intended fold is re-projected from its
      -- anchored intent. The old path deleted drifted folds one at a time
      -- with `zd`, which requires jumping the cursor to the fold and back on
      -- every flush — that up-and-back was the streaming flicker.
      vim.cmd("normal! zE")
      w.installed = {}
      local parts = {}
      for _, b in ipairs(list) do
        -- :fold creates a closed fold, so only explicitly opened folds need
        -- an extra command; the old :foldclose for every other fold was a
        -- no-op C round-trip per fold on every rebuild. Batching the whole
        -- projection into one `|`-joined Ex command keeps the rebuild off the
        -- O(folds) nvim_exec2 round-trip path as well.
        parts[#parts + 1] = ("%d,%dfold"):format(b.start, b.finish)
        if w.intent[b.id] == true then
          parts[#parts + 1] = ("%dfoldopen"):format(b.start)
        end
        w.installed[b.id] = { start = b.start, finish = b.finish }
      end
      if #parts > 0 then
        vim.cmd(table.concat(parts, " | "))
      end
    else
      -- Nothing moved: only install folds that are new to this window.
      local parts = {}
      for _, b in ipairs(list) do
        if not w.installed[b.id] then
          parts[#parts + 1] = ("%d,%dfold"):format(b.start, b.finish)
          if w.intent[b.id] == true then
            parts[#parts + 1] = ("%dfoldopen"):format(b.start)
          end
          w.installed[b.id] = { start = b.start, finish = b.finish }
        end
      end
      if #parts > 0 then
        vim.cmd(table.concat(parts, " | "))
      end
    end
    w.rebuild, w.reset, w.restore = false, false, false
    vim.fn.winrestview(saved)
  end)
end

function M.reconcile(buf, full, incremental)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local s = state(buf)
  local p = incremental == true and extend(buf) or parse(buf)
  local all = identify(buf, s, p)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local w = window(s, win)
    if full then
      w.rebuild = true
    end
    apply(buf, win, w, intended(all, w.view))
  end
  s.projected_tick = vim.api.nvim_buf_get_changedtick(buf)
end

function M.level(win)
  win = win or vim.api.nvim_get_current_win()
  local s = sessions[vim.api.nvim_win_get_buf(win)]
  if not s then
    return 2
  end
  local w = s.windows[win]
  return w and w.view or s.default_view
end

-- View resets affect this window only. A newly created window uses the last
-- selected view as its default, but never inherits another window's opens.
function M.set_view_level(level)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local s = state(buf)
  local w = window(s, win)
  s.default_view, w.view = level, level
  w.intent, w.rebuild, w.reset = {}, true, true
  apply(buf, win, w, intended(identify(buf, s, parse(buf)), level))
end

--- Apply an open/close choice to the fold containing `lnum`, using the
--- already-reconciled projection. Runs no `:normal` (only `:foldopen`/
--- `:foldclose`), so it is safe inside an expr map — the mouse handler relies
--- on this. Returns true when a matching fold was changed.
local function choose(lnum, action)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local s = sessions[buf]
  local w = s and s.windows[win]
  if not (w and s.folds) then
    return false
  end
  for _, b in ipairs(intended(s.folds, w.view)) do
    if lnum >= b.start and lnum <= b.finish then
      local open = action == "open" or action == "toggle" and vim.fn.foldclosed(b.start) ~= -1
      w.intent[b.id] = open
      local saved = vim.fn.winsaveview()
      vim.cmd(("%dfold%s"):format(b.start, open and "open" or "close"))
      vim.fn.winrestview(saved)
      return true
    end
  end
  return false
end

local function act(lnum, action)
  local buf = vim.api.nvim_get_current_buf()
  M.reconcile(buf)
  choose(lnum, action)
end

function M.open(lnum)
  act(lnum, "open")
end
function M.toggle(lnum)
  act(lnum, "toggle")
end

--- `<LeftMouse>` expr-map handler: open the fold under a click, or fall
--- through to Neovim's native click. Returning "<LeftMouse>" lets Neovim
--- perform its own press (cursor placement, window focus, drag-select) on
--- open lines; returning "" consumes the click after opening a closed fold
--- in place. The open path must not run `:normal` (forbidden inside an expr
--- map), so it relies on the buffer already being reconciled — which it is
--- between stream flushes and the scheduled edit reconcile — and applies the
--- open directly from the reconciled projection. Clicks in a background split
--- open the fold there without stealing focus (no WinEnter), matching the
--- winbar switch's window handling.
function M.mouse_left()
  local pos = vim.fn.getmousepos()
  local win = pos.winid
  if win == 0 or not vim.api.nvim_win_is_valid(win) or pos.line <= 0 then
    return "<LeftMouse>"
  end
  local folded = vim.api.nvim_win_call(win, function()
    return vim.fn.foldclosed(pos.line) ~= -1
  end)
  if not folded then
    return "<LeftMouse>"
  end
  vim.api.nvim_win_call(win, function()
    choose(pos.line, "open")
    vim.api.nvim_win_set_cursor(win, { pos.line, 0 })
  end)
  return ""
end

-- Capture before an edit: Neovim may remove a one-line manual fold when
-- that line is split. After the edit it is too late to recover its native
-- open/closed choice. Document mutations call this before writing. The stream
-- append path passes skip=true: only the tail fold can be split by a tail
-- append, so capturing just it (rather than every installed fold) keeps the
-- per-chunk cost off the O(folds) critical path.
function M.before_change(buf, skip)
  local s = sessions[buf]
  if not s then
    return
  end
  s.streaming = skip == true
  if skip == true then
    local lastline = vim.api.nvim_buf_line_count(buf)
    for win, w in pairs(s.windows) do
      local id, start = tail_installed(w, lastline)
      if id then
        capture_one(buf, win, w, id, start)
      end
    end
  else
    for win, w in pairs(s.windows) do
      capture(buf, win, w)
    end
  end
end

-- Text and its folds are committed before the stream callback yields. The
-- scheduled on_lines fallback subsequently sees identical ranges (a no-op).
function M.after_append(buf, incremental)
  local s = sessions[buf]
  if s then
    s.streaming = false
    if s.projected_tick ~= vim.api.nvim_buf_get_changedtick(buf) then
      M.reconcile(buf, false, incremental)
    end
  end
end

-- BufWinLeave does not fire if another split still shows this buffer.
-- Capture the departing window's native choices before they get replaced.
vim.api.nvim_create_autocmd("BufLeave", {
  group = group,
  callback = function(args)
    local s = sessions[args.buf]
    local win = vim.api.nvim_get_current_win()
    if s and s.windows[win] then
      capture(args.buf, win, s.windows[win])
    end
  end,
})
-- Session return must be synchronous: deferring it permits one unfolded
-- frame before repair. Mark a returning window for rebuild, because Neovim
-- may have restored different native folds while the buffer was hidden.
vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
  group = group,
  callback = function(args)
    local buf = vim.api.nvim_get_current_buf()
    local s = sessions[buf]
    if s then
      if s.detached then
        sessions[buf] = nil
        s = state(buf)
      end
      local win = vim.api.nvim_get_current_win()
      if args.event == "BufWinEnter" or not s.windows[win] then
        local w = window(s, win)
        w.rebuild, w.restore = true, true
        M.reconcile(buf)
      end
    end
  end,
})
vim.api.nvim_create_autocmd("BufWipeout", {
  group = group,
  callback = function(args)
    M.clear_text(args.buf)
  end,
})
vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    -- The closed window's handle. `args.win` only exists on 0.13+;
    -- `<afile>` (args.file) carries the same handle on every supported
    -- version, as a string.
    local win = tonumber(args.file)
    if not win then
      return
    end
    for _, s in pairs(sessions) do
      s.windows[win] = nil
    end
  end,
})

-- ─── foldtext ──────────────────────────────────────────────────────────────

-- Badge precedence: one leading badge per fold, the highest wins. Lower rank
-- wins; a fold that qualifies for several shows only the one that matters
-- most. The split between `denied` and `stopped` is the status/provenance
-- line: an abnormal outcome always beats a context badge, so an
-- auto-approved bash that exited 1 shows `[exit 1]`, never `[Auto-approved]`.
local RANK = {
  error = 1,
  timeout = 2,
  exit = 3,
  denied = 4,
  stopped = 5,
  cost_override = 6,
  approved = 7,
  cleared = 8,
  resumed = 9,
  forked = 10,
}

local function badge(label, hl, rank)
  return { label = label, hl = hl, rank = rank }
end

-- First index whose `key` is >= start (all event lists are ordered by line).
local function lower_bound(list, key, start)
  local lo, hi = 1, #list + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if list[mid][key] < start then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

local function pick_badge(cands)
  local best
  for _, c in ipairs(cands) do
    if c and (not best or c.rank < best.rank) then
      best = c
    end
  end
  return best
end

-- Guard decisions keyed by tool start (tool folds) or line within a range
-- (assistant folds). Returns candidate badges and, for tool folds, the latest
-- decision timestamp. A guard timeout and a process timeout share one color.
local function guard_candidates(p, start, finish, tool)
  local list = p.guard_decisions
  local key = tool and "tool_start" or "line"
  local lo = lower_bound(list, key, start)
  local last = tool and start or finish
  if not list[lo] or list[lo][key] > last then
    return nil, nil
  end
  local counts, date = {}, nil
  for i = lo, #list do
    local d = list[i]
    if d[key] > last then
      break
    end
    counts[d.outcome] = (counts[d.outcome] or 0) + 1
    date = d.ts or date
  end
  local cands = {}
  local function add(outcome, label, hl, rank)
    local n = counts[outcome]
    if n then
      cands[#cands + 1] = badge("[" .. label .. (n > 1 and " ×" .. n or "") .. "] ", hl, rank)
    end
  end
  add("timeout", "Timed out", "DiagnosticError", RANK.timeout)
  add("denied", "Denied", "DiagnosticError", RANK.denied)
  add("auto-approved", "Auto-approved", "Comment", RANK.approved)
  add("approved", "Approved", "Comment", RANK.approved)
  return cands, tool and date or nil
end

--- A long bash call's recorded duration in milliseconds, or nil when the
--- tool fold has none. Keyed by the tool region's start line, like guard
--- decisions.
local function duration_for(p, tool_start)
  local list = p.tool_durations
  local i = lower_bound(list, "tool_start", tool_start)
  if list[i] and list[i].tool_start == tool_start then
    return list[i].ms
  end
  return nil
end

--- Render a millisecond duration as a compact wall-clock label (42s,
--- 1m 05s, 2h 03m).
local function format_duration(ms)
  local s = math.floor(ms / 1000 + 0.5)
  if s < 60 then
    return s .. "s"
  end
  local m = math.floor(s / 60)
  if m < 60 then
    return ("%dm %02ds"):format(m, s % 60)
  end
  return ("%dh %02dm"):format(math.floor(m / 60), m % 60)
end

--- The tool region whose fold starts at `start`, or nil. Regions are ordered
--- by start line, so a binary search finds it without scanning the session.
local function tool_region(p, start)
  local regions = p.regions
  local lo, hi = 1, #regions + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if regions[mid].start < start then
      lo = mid + 1
    else
      hi = mid
    end
  end
  local r = regions[lo]
  if r and r.start == start and r.kind == "tool" then
    return r
  end
  return nil
end

--- An abnormal tool outcome's candidate badge, or nil when the tool completed
--- normally. Keyed by the tool region's start line.
local function outcome_candidate(p, tool_start)
  local list = p.tool_outcomes
  local i = lower_bound(list, "tool_start", tool_start)
  local d = list[i]
  if d and d.tool_start == tool_start then
    if d.outcome == "error" then
      return badge("[Error] ", "DiagnosticError", RANK.error)
    elseif d.outcome == "timeout" then
      return badge("[Timed out] ", "DiagnosticError", RANK.timeout)
    elseif d.outcome == "exit" then
      return badge(("[exit %d] "):format(d.code or 0), "DiagnosticWarn", RANK.exit)
    end
  end
  return nil
end

--- `[Cleared]` when :YapClear replaced this tool's result body.
local function cleared_candidate(p, tool_start)
  local r = tool_region(p, tool_start)
  if r and r.cleared then
    return badge("[Cleared] ", "Comment", RANK.cleared)
  end
  return nil
end

--- Added/removed line counts of a tool's display diff as colored chunks
--- (DiffAdd for additions, DiffDelete for removals), or nil when the diff
--- added and removed nothing.
local function diff_chunks(p, tool_start)
  local r = tool_region(p, tool_start)
  if not r then
    return nil
  end
  local plus, minus = r.diff_plus or 0, r.diff_minus or 0
  if plus == 0 and minus == 0 then
    return nil
  end
  local out = {}
  if plus > 0 then
    out[#out + 1] = { "+" .. plus, "DiffAdd" }
  end
  if plus > 0 and minus > 0 then
    out[#out + 1] = { "/", "Comment" }
  end
  if minus > 0 then
    out[#out + 1] = { "-" .. minus, "DiffDelete" }
  end
  return out
end

-- Events that badge a closed assistant fold. A stop marker lands inside the
-- reply it cut short; a cost override and a resume marker sit in the block
-- that precedes the reply they describe.
local function assistant_candidates(p, start, finish)
  local cands = {}
  for _, d in ipairs(p.events) do
    if d.kind == "cost_override" and d.assistant == start then
      cands[#cands + 1] = badge("[Cost override] ", "DiagnosticWarn", RANK.cost_override)
    elseif d.kind == "turn_stopped" and d.line >= start and d.line <= finish then
      if d.outcome == "killed" then
        cands[#cands + 1] = badge("[Force-stopped] ", "DiagnosticError", RANK.stopped)
      else
        cands[#cands + 1] = badge("[Stopped] ", "DiagnosticWarn", RANK.stopped)
      end
    elseif d.kind == "session_resumed" and d.assistant == start then
      cands[#cands + 1] = badge("[Resumed] ", "Comment", RANK.resumed)
    end
  end
  return cands
end

-- A fork is a session-level fact, so it badges the frontmatter fold.
local function frontmatter_candidates(p)
  for _, d in ipairs(p.events) do
    if d.kind == "session_forked" then
      return { badge("[Forked] ", "Comment", RANK.forked) }
    end
  end
  return {}
end

--- The single leading badge for a closed assistant fold. Exported so the
--- symbol picker and the fold renderer never disagree.
function M.assistant_badge(buf, start, finish)
  local p = parse(buf)
  local cands = {}
  local guard = guard_candidates(p, start, finish, false)
  if guard then
    for _, c in ipairs(guard) do
      cands[#cands + 1] = c
    end
  end
  for _, c in ipairs(assistant_candidates(p, start, finish)) do
    cands[#cands + 1] = c
  end
  return pick_badge(cands)
end

-- Evaluated by Vim for every visible closed fold on every screen draw.
function M.text(start, finish)
  start = start or vim.v.foldstart
  finish = finish or vim.v.foldend
  local buf = vim.api.nvim_get_current_buf()
  local p = parse(buf)
  local first = vim.fn.getline(start)

  local identity
  local dur
  local diff
  local cands = {}
  local date
  -- The line count is a live progress readout: it appears only while the
  -- block is still streaming in (its fold reaches the last line), then the
  -- settled fold drops it.
  local lines = finish == vim.api.nvim_buf_line_count(buf)
      and (" (%d lines)"):format(finish - start + 1)
    or nil

  if first:match("^%-%-%-%s*$") then
    identity = "▸ options"
    for _, c in ipairs(frontmatter_candidates(p)) do
      cands[#cands + 1] = c
    end
  elseif first:match(TOOL_OPEN) then
    -- The name is on the opener line (single-line header) or in the
    -- pretty JSON below (multi-line header).
    local name = first:match('"name":%s*"([^"]+)"')
    for lnum = start + 1, math.min(finish, start + 12) do
      if name then
        break
      end
      name = vim.fn.getline(lnum):match('"name":%s*"([^"]+)"')
    end
    identity = "▸ tool: " .. (name or "?")
    dur = duration_for(p, start)
    diff = diff_chunks(p, start)
    local outcome = outcome_candidate(p, start)
    if outcome then
      cands[#cands + 1] = outcome
    end
    local guard, tool_date = guard_candidates(p, start, finish, true)
    if guard then
      for _, c in ipairs(guard) do
        cands[#cands + 1] = c
      end
    end
    date = tool_date
    local cleared = cleared_candidate(p, start)
    if cleared then
      cands[#cands + 1] = cleared
    end
  else
    local region = first:match("^<!%-%-.*yap:(%a+)")
    if region then
      identity = "▸ yap: " .. region
    else
      local role = first:match(HEAD) or "?"
      local preview = ""
      for lnum = start + 1, finish do
        local s = view.collapse(vim.fn.getline(lnum))
        if s ~= "" then
          preview = s
          break
        end
      end
      if #preview > 60 then
        preview = view.clip(preview, 61)
      elseif preview == "" then
        preview = "(empty)"
      end
      identity = ("▸ @%s │ %s"):format(role, preview)
      if role == "assistant" then
        local guard = guard_candidates(p, start, finish, false)
        if guard then
          for _, c in ipairs(guard) do
            cands[#cands + 1] = c
          end
        end
        for _, c in ipairs(assistant_candidates(p, start, finish)) do
          cands[#cands + 1] = c
        end
      end
    end
  end

  local out = {}
  local win = pick_badge(cands)
  if win then
    out[#out + 1] = { win.label, win.hl }
  end
  out[#out + 1] = { identity, "Folded" }
  if dur then
    out[#out + 1] = { " · " .. format_duration(dur), "Comment" }
  end
  if diff then
    out[#out + 1] = { " · ", "Comment" }
    for _, c in ipairs(diff) do
      out[#out + 1] = c
    end
  end
  if lines then
    out[#out + 1] = { lines, "Comment" }
  end
  if date then
    out[#out + 1] = { "  " .. date:gsub("T", " ") .. " UTC", "Comment" }
  end
  if #out == 1 then
    return out[1][1]
  end
  return out
end

--- Drop a buffer's per-buffer state (BufWipeout). The tick checks already
--- invalidate on buffer-number reuse.
function M.clear_text(buf)
  structure.clear(buf)
  sessions[buf] = nil
end

-- ─── Message navigation ────────────────────────────────────────────────────

-- Message navigation uses the structural heading list (the same parse
-- folding projects), not vim.fn.search: a `# @user` line inside a fenced
-- tool result is literal content, not a message boundary, and a raw regex
-- search cannot see the fence.
local function message_jump(role, backwards)
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  local headings = parse(buf).headings
  if backwards then
    for i = #headings, 1, -1 do
      local h = headings[i]
      if h.line < cur and (not role or h.role == role) then
        target = h.line
        break
      end
    end
  else
    for _, h in ipairs(headings) do
      if h.line > cur and (not role or h.role == role) then
        target = h.line
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    return target
  end
  return 0
end

function M.next_message()
  return message_jump(nil, false)
end

function M.prev_message()
  return message_jump(nil, true)
end

function M.next_user_message()
  return message_jump("user", false)
end

function M.prev_user_message()
  return message_jump("user", true)
end

function M.next_assistant_message()
  return message_jump("assistant", false)
end

function M.prev_assistant_message()
  return message_jump("assistant", true)
end

-- Region navigation: the three display regions worth hopping between
-- when reviewing a long reply. Like message navigation, this uses the
-- fence- and comment-aware parse folding projects, not vim.fn.search: a
-- `<!-- yap:tool` line inside a fenced result, or inside a thinking region's
-- content (a model reasoning about a tool call quotes the marker verbatim),
-- is literal text, not a boundary, and a raw line search lands on it.
-- These also serve as x/o motions (v]t, d]c), so they move the cursor
-- directly; Neovim records the operator/visual range from that movement.
local function jump_region(kinds, backwards)
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  local regions = parse(buf).regions
  if backwards then
    for i = #regions, 1, -1 do
      local d = regions[i]
      if kinds[d.kind] and d.start < cur then
        target = d.start
        break
      end
    end
  else
    for _, d in ipairs(regions) do
      if kinds[d.kind] and d.start > cur then
        target = d.start
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    return target
  end
  return 0
end

-- `]t`/`[t` hop between tool calls and thinking: both are machine regions
-- worth reviewing, and a tool call is usually preceded by thinking. `]c`
-- remains thinking-only.
local TOOL_OR_THINK = { tool = true, thinking = true }
local THINK_ONLY = { thinking = true }
local ERROR_ONLY = { error = true }

function M.next_tool()
  return jump_region(TOOL_OR_THINK, false)
end

function M.prev_tool()
  return jump_region(TOOL_OR_THINK, true)
end

function M.next_think()
  return jump_region(THINK_ONLY, false)
end

function M.prev_think()
  return jump_region(THINK_ONLY, true)
end

function M.next_error()
  return jump_region(ERROR_ONLY, false)
end

function M.prev_error()
  return jump_region(ERROR_ONLY, true)
end

-- ─── Buffer setup ──────────────────────────────────────────────────────────

function M.setup_buffer(buf, keys)
  keys = keys or require("harness").config.keymaps
  -- Fold state must exist before the buffer is shown: a hidden session
  -- (:YapEval, a subagent) is created while another buffer is current, so
  -- set_view_level's current-window path cannot install its folds. Initializing
  -- the state here lets the BufWinEnter handler project the default view the
  -- first time the buffer appears in a window.
  local s = state(buf)
  s.default_view = 2 -- default: conversation open, tools & thinking folded
  if vim.api.nvim_get_current_buf() == buf then
    M.set_view_level(2)
  end

  local map = function(lhs, rhs, desc)
    if lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = "yap: " .. desc })
  end
  -- Also as motions: visual (`v]t` selects to the next tool) and
  -- operator-pending (`d]c` deletes to the next thinking region).
  local map_motion = function(lhs, rhs, desc)
    if lhs == "" then
      return
    end
    vim.keymap.set({ "x", "o" }, lhs, rhs, { buffer = buf, silent = true, desc = "yap: " .. desc })
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
  local region_jump = function(fn)
    return function()
      if fn() ~= 0 then
        M.open(vim.api.nvim_win_get_cursor(0)[1])
      end
    end
  end
  map(keys.next_tool, region_jump(M.next_tool), "Next tool call or thinking region")
  map(keys.prev_tool, region_jump(M.prev_tool), "Previous tool call or thinking region")
  map(keys.next_think, region_jump(M.next_think), "Next thinking region")
  map(keys.prev_think, region_jump(M.prev_think), "Previous thinking region")
  map(keys.next_error, region_jump(M.next_error), "Next error region")
  map(keys.prev_error, region_jump(M.prev_error), "Previous error region")
  map_motion(keys.next_tool, M.next_tool, "Select to next tool call or thinking region")
  map_motion(keys.prev_tool, M.prev_tool, "Select to previous tool call or thinking region")
  map_motion(keys.next_think, M.next_think, "Select to next thinking region")
  map_motion(keys.prev_think, M.prev_think, "Select to previous thinking region")
  map_motion(keys.next_error, M.next_error, "Select to next error region")
  map_motion(keys.prev_error, M.prev_error, "Select to previous error region")
  local bind_view = function(key, level, desc)
    map(key, function()
      M.set_view_level(level)
    end, desc)
  end
  bind_view(keys.view_1, 1, "Fold all agent messages (user prompts stay open)")
  bind_view(keys.view_2, 2, "Fold all tool calls and thinking regions")
  bind_view(keys.view_3, 3, "Unfold everything")
  map(keys.toggle_fold, function()
    M.toggle(vim.api.nvim_win_get_cursor(0)[1])
  end, "Toggle fold")
  -- A click on a closed fold opens it; clicks on open content keep native
  -- mouse behavior (cursor placement and drag-select).
  vim.keymap.set("n", "<LeftMouse>", M.mouse_left, {
    buffer = buf,
    expr = true,
    silent = true,
    desc = "yap: open fold on click",
  })
  -- Native user commands update the same state as Tab, including closes.
  -- normal! and Ex commands are also observed before stream edits/leaving.
  for _, command in ipairs({ "za", "zo", "zc", "zA", "zO", "zC", "zR", "zM", "zr", "zm" }) do
    map(command, function()
      -- zo/zc/za raise E490 "No fold found" when the cursor is not on a
      -- fold (or is already in the target state); silent! keeps that a
      -- no-op instead of an E5108 Lua stack trace.
      vim.cmd("silent! normal! " .. (vim.v.count > 0 and tostring(vim.v.count) or "") .. command)
      M.before_change(buf)
    end, command)
  end
end

M.parse = parse

return M
