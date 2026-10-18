-- Yap folds are a projection of structural units, not their identity.
-- Extmarks anchor folds through edits/undo. Each window owns its view and
-- explicit open/closed choices. Native folds are observed before replacing
-- changed ranges, so Tab, za/zo/zc and Ex fold commands have the same meaning.
-- Views remain flat: messages in view 1, regions in view 2, none in view 3.

local M = {}

local structure = require("harness.structure")
local view = require("harness.view")
local HEAD = structure.HEAD
local TOOL_OPEN = structure.TOOL_OPEN
local TOOL_CLOSE = structure.TOOL_CLOSE
local COMMENT_OPEN = structure.COMMENT_OPEN
local parse = structure.parse
local fence_run = structure.fence_run

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

-- One O(n) forward pass over the buffer produces the structural units the
-- three views fold. Fences and multi-line HTML comments are tracked so a
-- fake `# @user` inside a fenced tool result, or a `-->` inside a fence,
-- can't split the structure. This mirrors the old classify() state machine
-- but emits fold ranges instead of per-line level strings.
--
--   headings = { {role="system"|"user"|"assistant", line}, … }  (in order)
--   regions  = { {kind="tool"|"thinking"|"error"|…, start, finish}, … }
--              finish is nil while a region is still open (streaming).

-- ─── identity, intent and projection ───────────────────────────────────────

local anchors = vim.api.nvim_create_namespace("yap.fold.regions")
local sessions = {} -- buf -> fold identities and per-window projections
local group = vim.api.nvim_create_augroup("YapFolds", { clear = true })

-- User edits/undo reconcile on a pause, not per keystroke: extmarks and
-- native manual folds already track the edit, so the full O(n) reparse can
-- wait until typing stops. Stream appends are unaffected (they reconcile
-- synchronously via after_append before yielding).
local IDLE_RECONCILE_MS = 150

local function position(buf, id)
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, anchors, id, { details = true })
  if #mark == 0 or mark[3].invalid then
    return nil
  end
  return mark[1] + 1
end

-- Only actual native folds are observed. Missing/deleted folds are not
-- mistaken for user opens, and disabling folding does not pin everything.
-- With manual folds there is no foldexpr/lazy recomputation to confuse this
-- observation. on_lines sees both native ranges and extmarks AFTER shifting.
local function capture(buf, win, w)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  vim.api.nvim_win_call(win, function()
    if not vim.wo.foldenable then
      return
    end
    for id in pairs(w.installed) do
      local row = position(buf, id)
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
  s = { records = {}, windows = {}, default_view = 2 }
  sessions[buf] = s
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      for win, w in pairs(s.windows) do
        capture(buf, win, w)
      end
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
  local at = {}
  for id, kind in pairs(s.records) do
    local row = position(buf, id)
    if row then
      at[row] = at[row] or {}
      at[row][kind] = id
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
  for i, h in ipairs(p.headings) do
    add("message:" .. h.role, h.line, p.headings[i + 1] and p.headings[i + 1].line - 1 or p.count)
  end
  for _, d in ipairs(p.regions) do
    add("region:" .. d.kind, d.start, d.finish or p.count)
  end
  table.sort(all, function(a, b)
    return a.start < b.start
  end)
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
  vim.wo.foldtext = "v:lua.require'harness.fold'.text()"
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
      for id, old in pairs(w.installed) do
        local b = wanted[id]
        if
          position(buf, id) ~= old.start
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
      for _, b in ipairs(list) do
        vim.cmd(("%d,%dfold"):format(b.start, b.finish))
        vim.cmd(("%dfold%s"):format(b.start, w.intent[b.id] == true and "open" or "close"))
        w.installed[b.id] = { start = b.start, finish = b.finish }
      end
    else
      -- Nothing moved: only install folds that are new to this window.
      for _, b in ipairs(list) do
        if not w.installed[b.id] then
          vim.cmd(("%d,%dfold"):format(b.start, b.finish))
          vim.cmd(("%dfold%s"):format(b.start, w.intent[b.id] == true and "open" or "close"))
          w.installed[b.id] = { start = b.start, finish = b.finish }
        end
      end
    end
    w.rebuild, w.reset, w.restore = false, false, false
    vim.fn.winrestview(saved)
  end)
end

function M.reconcile(buf, full)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local s = state(buf)
  local all = identify(buf, s, parse(buf))
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

-- Capture before a stream edit: Neovim may remove a one-line manual fold
-- when that line is split. After the edit it is too late to recover its
-- native open/closed choice. Document mutations call this before writing.
function M.before_change(buf)
  local s = sessions[buf]
  if s then
    for win, w in pairs(s.windows) do
      capture(buf, win, w)
    end
  end
end

-- Text and its folds are committed before the stream callback yields. The
-- scheduled on_lines fallback subsequently sees identical ranges (a no-op).
function M.after_append(buf, _)
  local s = sessions[buf]
  if s and s.projected_tick ~= vim.api.nvim_buf_get_changedtick(buf) then
    M.reconcile(buf)
  end
end

-- Session return must be synchronous: deferring it permits one unfolded
-- frame before repair. Mark a returning window for rebuild, because Neovim
-- may have restored different native folds while the buffer was hidden.
vim.api.nvim_create_autocmd("BufWinLeave", {
  group = group,
  callback = function(args)
    local s = sessions[args.buf]
    local win = vim.api.nvim_get_current_win()
    if s and s.windows[win] then
      capture(args.buf, win, s.windows[win])
    end
  end,
})
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

  if first:match("^%-%-%-%s*$") then
    text = string.format("▸ options (%d lines)", finish - start + 1)
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
    text = string.format("▸ tool: %s (%d lines)", name or "?", finish - start + 1)
  else
    local region = first:match("^<!%-%-.*yap:(%a+)")
    if region then
      text = string.format("▸ yap: %s (%d lines)", region, finish - start + 1)
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
  options()
  M.set_view_level(2) -- default: conversation open, tools & thinking folded

  local map = function(lhs, rhs, desc)
    if lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  -- Also as motions: visual (`v]t` selects to the next tool) and
  -- operator-pending (`d]c` deletes to the next thinking region).
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
    end, "Yap: " .. command)
  end
end

-- Exposed for the shared Go/Lua fence conformance test (see
-- tests/fence_cases.json) and the perf profiler. Not part of the public API.
M.fence_run = fence_run
M.parse = parse

return M
