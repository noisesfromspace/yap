-- Fixed-height bottom drawers: the ONE toggle pattern shared by the audit
-- view (:YapLive) and the scratch queue (<leader>s). A single persistent
-- buffer, never duplicated, always a bottom split under the session's own
-- window, and closed back to the window it was toggled from.

local M = {}

local state = require("harness.state")

-- The session window each open drawer is anchored to, so closing the drawer
-- returns the cursor to the window it was toggled from (never stranded on
-- a dead window or jumped to an unrelated one).
local drawer_anchor = {} -- drawer bufnr -> owner window id

--- Open or close a fixed-height drawer below the session window. Anchoring the
--- split to a window showing `owner` keeps the drawer in the session's own
--- column when the session shares a vertical split — `belowright` splits the
--- anchor window, so the drawer never spans the whole tab.
function M.toggle(owner, bufnr, height)
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins > 0 then
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
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
  if anchor and vim.api.nvim_win_is_valid(anchor) then
    vim.api.nvim_set_current_win(anchor)
  end
  vim.cmd("belowright " .. height .. "split")
  vim.api.nvim_win_set_buf(0, bufnr)
  drawer_anchor[bufnr] = anchor
  return true
end

--- Close every window showing `buf`, keeping the drawer buffer itself so it
--- can be reopened. `owner` is the session buffer the drawer belongs to.
function M.close(buf, owner)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      -- tabpage_list_wins includes floating windows, but Neovim cannot
      -- close the last ordinary window of a tab (E444), even with floats.
      local tab = vim.api.nvim_win_get_tabpage(win)
      local normal = 0
      for _, other in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_win_get_config(other).relative == "" then
          normal = normal + 1
        end
      end
      if normal > 1 then
        vim.api.nvim_win_close(win, true)
      elseif state.pending_approvals[owner] and win == vim.api.nvim_get_current_win() then
        -- Inspect + :only while focused on the audit: keep the review
        -- visible, not an empty replacement buffer. :YapGuard still
        -- works from this window even when the session is hidden.
      else
        -- Keep the drawer buffer available to reopen later.
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
      end
    end
  end
  drawer_anchor[buf] = nil
end

return M
