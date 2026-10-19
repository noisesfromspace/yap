-- Session listing and navigation: the open-session pickers, the live tool
-- tail, guard-board call reveal, and "which session owns this buffer".

local M = {}

local state = require("harness.state")
local picker = require("harness.ui.picker")
local frontmatter = require("harness.model.frontmatter")
local session = require("harness.session")
local drawer = require("harness.ui.drawer")
local audit = require("harness.agent.audit")
local guard = require("harness.ui.guard")
local buffers = require("harness.session.buffers")

local stopped = state.stopped
local errors = state.errors
local awaiting = state.awaiting
local pending_approvals = state.pending_approvals
local subagent_children = state.subagent_children
local follow_override = state.follow_override

local function harness()
  return require("harness")
end


--- The session buffer a yap panel belongs to: a session buffer itself, the
--- live tail's owning session, or the scratch/guard board's recorded
--- `yap_owner`. Returns nil for a buffer that is not part of any session.
function M.session_of(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  if vim.b[buf].yap then
    return buf
  end
  for owner, t in pairs(audit.views()) do
    if t.bufnr == buf then
      return owner
    end
  end
  local owner = vim.b[buf].yap_owner
  if owner and vim.api.nvim_buf_is_valid(owner) and vim.b[owner].yap then
    return owner
  end
  return nil
end

--- The session's live tail buffer, or nil before it has been created (used to
--- detect whether the tail is on screen without forcing it into existence).
function M.tail_buffer(buf)
  local t = audit.view(buf)
  return t and t.bufnr or nil
end

--- Open the session's live tool tail (:YapLive): one persistent read-only
--- buffer that follows the running tool's output. Opens even before any tool
--- has run (an empty tail that fills as tools execute). The tail stacks below
--- the guard board when it is open in this tab, else below the session window
--- — the canonical session → guard → log column.
function M.live(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local owner = M.session_of(buf)
  if not owner then
    vim.notify("yap: live tool tail needs a yap session", vim.log.levels.WARN)
    return
  end

  local t = audit.ensure(owner)
  local anchor = drawer.win_in_tab(guard.buf(), vim.api.nvim_get_current_tabpage())
  local split = "below"
  if not anchor then
    anchor = drawer.owner_window(owner)
  end

  if not drawer.open_at(t.bufnr, drawer.half_screen(), nil, split, anchor) then
    return
  end
  audit.refresh(owner) -- a rule drawn while hidden may not match this window's width
  if harness().config.keymaps.live ~= "" then
    vim.keymap.set("n", harness().config.keymaps.live, function()
      M.live(t.bufnr)
    end, { buffer = t.bufnr, silent = true, desc = "yap: toggle live tool output" })
  end
  vim.keymap.set("n", "q", function()
    M.live(t.bufnr)
  end, { buffer = t.bufnr, silent = true, desc = "yap: close live view" })
  if harness().config.keymaps.guard ~= "" then
    vim.keymap.set("n", harness().config.keymaps.guard, function()
      guard.toggle()
    end, { buffer = t.bufnr, silent = true, desc = "yap: guard board" })
  end
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(t.bufnr), 0 })
end

--- Focus the matching tool region in the session. The audit records calls
--- even if the user later edits their transcript, so a missing region simply
--- leaves the session cursor where it was. `call` is the { id, occurrence }
--- of the tool call to reveal.
local function focus_approval_call(buf, call)
  if not call then
    return
  end
  local win = vim.fn.win_findbuf(buf)[1]
  if not win then
    return
  end
  local seen = 0
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, detail in ipairs(require("harness.model.structure").parse(buf).regions) do
    if detail.kind == "tool" then
      local id
      for i = detail.start, math.min(detail.start + 4, #lines) do
        id = lines[i]:match('"id"%s*:%s*"([^"\\]+)"')
        if id or lines[i]:find("-->", 1, true) then
          break
        end
      end
      if id == call.id then
        seen = seen + 1
        if seen == call.occurrence then
          -- A guard-board inspection wins over tail-following for this turn.
          local paused = follow_override[buf]
          if paused then
            paused[win] = true
          end
          vim.api.nvim_win_call(win, function()
            vim.api.nvim_win_set_cursor(win, { detail.start, 0 })
            vim.cmd("normal! zvzz")
          end)
          return
        end
      end
    end
  end
end
--- Open a session and focus the tool region a guard row points at. `call` is
--- the { id, occurrence } of the tool call (nil for rows without one). The
--- guard board's Inspect action uses this for rows loaded from disk, whether
--- or not the session is already open.
function M.reveal_call(path, call)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    buffers.focus_buf(buf)
    buffers.adopt(buf, path)
  else
    buf = buffers.open(path)
  end
  focus_approval_call(buf, call)
end

--- Find an open buffer for a saved session and return its live picker status.
local function saved_session_status(path)
  local normalized = vim.fs.normalize(path)
  -- An open history row has a state icon, even when idle; closed rows have
  -- no status column, so they sit flush against the picker's left edge.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buf].yap then
      local name = vim.b[buf].yap_path or vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fs.normalize(name) == normalized then
        return picker.status(buf)
      end
    end
  end
end

--- Pick a saved session and open it. scope: "cwd" (default) or "all".
function M.sessions(scope)
  require("harness.session").pick({ scope = scope, status = saved_session_status }, function(path)
    buffers.open(path)
  end)
end

--- Alias for the saved-session history picker.
function M.history(scope)
  M.sessions(scope)
end
--- Sort waiting sessions last; their dedicated <leader>w picker
--- makes them easy to reach without letting them crowd the general list.
local function session_rank(buf)
  local s = picker.state(buf)
  if s == "error" then
    return 1
  elseif s == "running" then
    return 2
  elseif s == "stopped" then
    return 3
  elseif s == "waiting" then
    return 5
  end
  return 4 -- idle and done
end

--- Every open yap session buffer, annotated with its live state and sorted with
--- waiting sessions last. The needs-you picker omits the current leaf session,
--- but keeps a current parent when it has open children to group beneath it.
--- An optional `state` narrows the list: a state name ("running", "error",
--- "waiting", "stopped" or "idle"), a set of them (a table keyed by state
--- name), or nil for all. The
--- "needs you" includes ordinary waiting/stopped parents, but only stopped
--- or errored children: a finished child need not be replied to. A current
--- parent remains visible while it has an open subagent. Audit views are
--- never here — use :YapLive / <leader>l.
local function has_open_child(parent)
  local child = subagent_children[parent]
  if child and vim.api.nvim_buf_is_valid(child) then
    return true
  end
  local path = vim.fs.normalize(vim.b[parent].yap_path or vim.api.nvim_buf_get_name(parent))
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= parent and vim.b[buf].yap then
      if vim.b[buf].yap_subagent_parent == parent then
        return true
      end
      local e = frontmatter.end_line(buf)
      local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false)) or nil
      if
        fm
        and (
          (fm.forked_from and vim.fs.normalize(fm.forked_from) == path)
          or (fm.subagent_parent and vim.fs.normalize(fm.subagent_parent) == path)
        )
      then
        return true
      end
    end
  end
  return false
end

function M.instances(state)
  -- Normalize `state` to a set keyed by state name, or nil for "all".
  local states = state
  if type(state) == "string" then
    states = { [state] = true }
  end
  -- The "needs you" picker is the waiting + stopped set.
  local needs_you = states ~= nil and states.waiting == true and states.stopped == true
  local items = {}
  local current = vim.api.nvim_get_current_buf()
  local open_paths = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].yap then
      open_paths[vim.fs.normalize(vim.b[b].yap_path or vim.api.nvim_buf_get_name(b))] = b
    end
  end
  local attention_child = {}
  if needs_you then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local parent = vim.b[b].yap_subagent_parent
      if parent and vim.b[b].yap and (stopped[b] or errors[b]) then
        attention_child[parent] = true
      end
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local subagent_parent = vim.b[b].yap_subagent_parent
    local e = vim.b[b].yap and frontmatter.end_line(b)
    local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(b, 0, e, false)) or nil
    subagent_parent = subagent_parent
      or (fm and fm.subagent_parent and open_paths[vim.fs.normalize(fm.subagent_parent)])
    local fork_parent = fm and fm.forked_from and open_paths[vim.fs.normalize(fm.forked_from)]
    local parent = subagent_parent or fork_parent
    local is_subagent = fm and fm.agent or vim.b[b].yap_agent
    local include_current = not needs_you or (b == current and has_open_child(b))
    local child_needs_you = is_subagent and (stopped[b] or errors[b])
    if
      (b ~= current or include_current)
      and vim.b[b].yap
      and (not needs_you or not is_subagent or child_needs_you)
      and (states == nil or states[picker.state(b)] or (needs_you and (child_needs_you or attention_child[b])))
    then
      items[#items + 1] = {
        buf = b,
        text = session.live_label(b, parent ~= nil),
        path = parent and "" or vim.b[b].yap_project_cwd,
        state = picker.state(b),
        approval = pending_approvals[b] ~= nil,
        model = vim.b[b].yap_model,
        child = is_subagent or (fm and fm.forked_from),
        group_parent = (parent and vim.api.nvim_buf_is_valid(parent)) and parent or b,
        parent = parent,
        forked_from = fm and fm.forked_from,
      }
    end
  end
  if #items == 0 then
    if needs_you then
      local message = "yap: no conversations need a reply"
      if vim.b[current].yap and states[picker.state(current)] then
        message = "yap: this conversation is already open and waiting for your reply"
      end
      vim.notify(message, vim.log.levels.INFO)
    else
      vim.notify("yap: no open conversations", vim.log.levels.INFO)
    end
    return
  end
  -- Sort roots by state; keep each child directly below its parent.
  local by_buf, children = {}, {}
  for _, item in ipairs(items) do
    by_buf[item.buf] = item
  end
  local roots = {}
  for _, item in ipairs(items) do
    if item.parent and by_buf[item.parent] then
      local siblings = children[item.parent] or {}
      siblings[#siblings + 1] = item
      children[item.parent] = siblings
    else
      if item.parent then
        item.path = vim.b[item.buf].yap_project_cwd
        item.text = item.text:sub(#"↳ " + 1) .. " (parent not shown)"
      end
      roots[#roots + 1] = item
    end
  end
  table.sort(roots, function(a, b)
    local ra, rb = session_rank(a.buf), session_rank(b.buf)
    if ra ~= rb then
      return ra < rb
    end
    return a.text < b.text
  end)
  local ordered = {}
  local function add(item, depth)
    item.depth = depth
    ordered[#ordered + 1] = item
    local siblings = children[item.buf] or {}
    table.sort(siblings, function(a, b)
      return a.text < b.text
    end)
    for _, child in ipairs(siblings) do
      add(child, depth + 1)
    end
  end
  for _, item in ipairs(roots) do
    add(item, 0)
  end
  items = ordered
  -- Keep icons in a fixed column; indent titles, not the status column.
  -- Disambiguate roots by project only when this picker spans projects.
  local projects = {}
  for _, item in ipairs(items) do
    projects[vim.b[item.buf].yap_project_cwd or ""] = true
  end
  local multiple_projects = vim.tbl_count(projects) > 1
  local glyph = picker.glyphs()
  local icon_width = picker.icon_width(glyph)
  vim.ui.select(items, {
    prompt = needs_you and "yap waiting" or "yap sessions",
    format_item = function(item)
      local suffix = multiple_projects and item.path and item.path ~= "" and (" (" .. item.path .. ")") or ""
      local icon = (item.approval and glyph.approval) or glyph[item.state]
      return picker.prefix(icon, icon_width)
        .. string.rep("  ", item.depth)
        .. item.text
        .. suffix
    end,
    preview_item = function(item)
      if not vim.api.nvim_buf_is_valid(item.buf) then
        return nil -- a session can close while the picker is open
      end
      return require("harness.session").preview(vim.api.nvim_buf_get_lines(item.buf, 0, -1, false))
    end,
  }, function(choice)
    if choice and vim.api.nvim_buf_is_valid(choice.buf) and vim.api.nvim_buf_is_loaded(choice.buf) then
      buffers.focus_buf(choice.buf)
    end
  end)
end

--- Just the sessions needing a reply — waiting for one or manually stopped —
--- the "needs you" set (<leader>w).
function M.waiting()
  M.instances({ waiting = true, stopped = true })
end

return M
