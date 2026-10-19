-- Fixed-height bottom drawers: the ONE window pattern shared by every Yap
-- panel — the live tool tail (:YapLive), the guard board (:YapGuard) and the
-- scratch queue (<leader>s). A single persistent buffer per panel, never
-- duplicated, always a bottom split under the panel's own anchor window,
-- closed back to the window it was toggled from. All three share the same
-- window options so they look and behave alike.

local M = {}

local state = require("harness.state")

local drawer_anchor = {} -- drawer bufnr -> owner window id

-- Number of ordinary (non-floating) windows in a tabpage. Floats appear in
-- tabpage_list_wins but cannot keep a tab alive: only ordinary windows count
-- when deciding whether closing a drawer would raise E444.
local function normal_windows(tab)
  local n = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      n = n + 1
    end
  end
  return n
end

--- The shared panel window options. `editable` marks the scratch jotter; the
--- read-only panels (audit, guard) additionally drop line numbers and the
--- sign column so a streaming projection reads as a dashboard, not a buffer.
function M.style(win, opts)
  opts = opts or {}
  vim.wo[win].winfixheight = true
  -- Panels are plain windows, never 'winfixbuf'-pinned: :e and file pickers
  -- must be able to reuse them like any other window. Their buffers survive
  -- (bufhidden = hide) and reopen via their toggle (<leader>g / <leader>l /
  -- <leader>s), so clobbering a panel view never loses data.
  vim.wo[win].winbar = "" -- the yap winbar is for sessions, not panels
  if not opts.editable then
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].cursorline = true
    -- Long single commands (a curl with many -H/-d flags, a long git line)
    -- have no shell operator to break at, so soft-wrap them at word
    -- boundaries with a hanging indent. Display-only: 'linebreak' never
    -- inserts newlines, so folds and per-line highlights are unaffected.
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
  end
end

-- Close one drawer window. A drawer that is the tab's last ordinary window
-- cannot be nvim_win_close'd (E444); :q on it closes the tab instead, the
-- same as native :q on a last window.
local function close_win(win)
  local tab = vim.api.nvim_win_get_tabpage(win)
  if normal_windows(tab) <= 1 then
    vim.api.nvim_set_current_win(win)
    vim.cmd("q")
  else
    vim.api.nvim_win_close(win, true)
  end
end

--- Half the screen height, for the large read-only panels (guard, audit).
--- Split heights are row counts, so a bottom drawer at this height fills the
--- bottom half of the tab while the anchor keeps the top half.
function M.half_screen()
  return math.max(1, math.floor(vim.o.lines / 2))
end

--- Close every window showing `bufnr`, restoring focus to the window the
--- drawer was toggled from (its stored anchor). Returns true when a window
--- was closed.
local function close_windows(bufnr)
  local closed = false
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      close_win(win)
      closed = true
    end
  end
  local anchor = drawer_anchor[bufnr]
  if anchor and vim.api.nvim_win_is_valid(anchor) then
    vim.api.nvim_set_current_win(anchor)
  end
  drawer_anchor[bufnr] = nil
  return closed
end

--- First window in `tab` showing `buf`, or nil. Restricts the search to one
--- tabpage so the guard board and live tail stay stacked in the same tab even
--- when the same (global) buffer is shown elsewhere.
function M.win_in_tab(buf, tab)
  if not buf then
    return nil
  end
  tab = tab or vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == tab then
      return win
    end
  end
  return nil
end

--- The window a drawer splits under by default: the current window when it
--- shows `owner` (stay where the user toggled from), else the first window
--- showing `owner`, else nil (split the current window).
function M.owner_window(owner)
  local wins = vim.fn.win_findbuf(owner)
  local cur = vim.api.nvim_get_current_win()
  if vim.tbl_contains(wins, cur) then
    return cur
  elseif #wins > 0 and vim.api.nvim_win_is_valid(wins[1]) then
    return wins[1]
  end
  return nil
end

--- Open or close a fixed-height drawer below the session window. Anchoring the
--- split to a window showing `owner` keeps the drawer in the session's own
--- column when the session shares a vertical split — splitting the anchor
--- window means the drawer never spans the whole tab. Returns the new window
--- when opened, nil when closed.
function M.toggle(owner, bufnr, height, opts)
  return M.open_at(bufnr, height, opts, "below", M.owner_window(owner))
end

--- Open `bufnr` as a drawer at an explicit anchor, or close it when already
--- visible (toggle). `split` is "below" (default) or "above"; `anchor` is the
--- window to split. The guard board passes the live tail's window to stack
--- above it; the live tail passes the guard window to stack below it — both
--- sides of the one canonical session → guard → log column.
function M.open_at(bufnr, height, opts, split, anchor)
  opts = opts or {}
  split = split or "below"
  if close_windows(bufnr) then
    return nil
  end

  -- nvim_open_win with an explicit split/win is deterministic: it splits the
  -- anchor window itself (no :belowright + current-window dance) and no
  -- autocommands can reshuffle the fresh layout mid-open.
  local win = vim.api.nvim_open_win(bufnr, true, {
    split = split,
    win = anchor or 0,
    height = height,
    noautocmd = true,
  })
  M.style(win, opts)
  drawer_anchor[bufnr] = anchor
  return win
end

--- Close every window showing `buf`, keeping the drawer buffer itself so it
--- can be reopened. `owner` is the session buffer the drawer belongs to.
function M.close(buf, owner)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      local tab = vim.api.nvim_win_get_tabpage(win)
      if normal_windows(tab) > 1 then
        vim.api.nvim_win_close(win, true)
      elseif state.pending_approvals[owner] and win == vim.api.nvim_get_current_win() then
        -- Inspect + :only while focused on the audit: keep the review
        -- visible, not an empty replacement buffer. :YapGuard still works
        -- from this window even when the session is hidden.
      else
        -- Keep the drawer buffer available to reopen later. Clear any pin
        -- options for the swap; its replacement is an ordinary empty buffer,
        -- not a drawer, so a pin stays cleared.
        vim.wo[win].winfixbuf = false
        vim.wo[win].winfixheight = false
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
      end
    end
  end
  drawer_anchor[buf] = nil
end

return M
