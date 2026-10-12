-- Fixed-height bottom drawers: the ONE window pattern shared by every Yap
-- panel — the audit view (:YapLive), the guard board (:YapGuard) and the
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
  vim.wo[win].winfixbuf = true -- pinned: a stray :e must not clobber the panel
  vim.wo[win].winbar = "" -- the yap winbar is for sessions, not panels
  if not opts.editable then
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].cursorline = true
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

--- Open or close a fixed-height drawer below the session window. Anchoring the
--- split to a window showing `owner` keeps the drawer in the session's own
--- column when the session shares a vertical split — splitting the anchor
--- window means the drawer never spans the whole tab. Returns true when the
--- drawer was opened, false when it was closed.
function M.toggle(owner, bufnr, height, opts)
  opts = opts or {}
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins > 0 then
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        close_win(win)
      end
    end
    local anchor = drawer_anchor[bufnr]
    if anchor and vim.api.nvim_win_is_valid(anchor) then
      vim.api.nvim_set_current_win(anchor)
    end
    drawer_anchor[bufnr] = nil
    return false
  end

  local owner_wins = vim.fn.win_findbuf(owner)
  local cur = vim.api.nvim_get_current_win()
  local anchor
  if vim.tbl_contains(owner_wins, cur) then
    anchor = cur -- stay where the user toggled from
  elseif #owner_wins > 0 and vim.api.nvim_win_is_valid(owner_wins[1]) then
    anchor = owner_wins[1]
  end

  -- nvim_open_win with an explicit split/win is deterministic: it splits the
  -- anchor window itself (no :belowright + current-window dance) and no
  -- autocommands can reshuffle the fresh layout mid-open.
  local win = vim.api.nvim_open_win(bufnr, true, {
    split = "below",
    win = anchor or 0,
    height = height,
    noautocmd = true,
  })
  M.style(win, opts)
  drawer_anchor[bufnr] = anchor
  return true
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
        -- Keep the drawer buffer available to reopen later. The window is
        -- pinned, so clear the pin options for the swap; its replacement is
        -- an ordinary empty buffer, not a drawer, so the pin stays cleared.
        vim.wo[win].winfixbuf = false
        vim.wo[win].winfixheight = false
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
      end
    end
  end
  drawer_anchor[buf] = nil
end

return M
