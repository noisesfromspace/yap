-- Session listing and navigation: the session pickers, the live tool
-- tail, guard-board call reveal, and "which session owns this buffer".

local M = {}

local state = require("harness.state")
local picker = require("harness.ui.picker")
local frontmatter = require("harness.model.frontmatter")
local session = require("harness.session")
local drawer = require("harness.ui.drawer")
local audit = require("harness.client.audit")
local guard = require("harness.ui.guard")
local buffers = require("harness.session.buffers")

local pending_approvals = state.pending_approvals
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
    if t.bufnr == buf and vim.api.nvim_buf_is_valid(owner) and vim.b[owner].yap then
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

--- Open the session's live tool tail (live()): one persistent read-only
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

  if not drawer.open_at(t.bufnr, drawer.half_screen(anchor), nil, split, anchor) then
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
  end, { buffer = t.bufnr, silent = true, desc = "yap: close tail viewer" })
  if harness().config.keymaps.guard ~= "" then
    vim.keymap.set("n", harness().config.keymaps.guard, function()
      guard.toggle()
    end, { buffer = t.bufnr, silent = true, desc = "yap: guard board" })
  end
  vim.keymap.set("n", "Y", function()
    audit.copy_command(owner, vim.api.nvim_win_get_cursor(0)[1])
  end, { buffer = t.bufnr, silent = true, desc = "yap: copy bash command" })
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

--- Pick a session and open it. scope: "cwd" (default), "all", or "open"
--- (the live open-session tree, including subagents and forks).
local open_sessions

function M.sessions(scope)
  if scope == "open" then
    return open_sessions()
  end
  require("harness.session").pick({ scope = scope, status = saved_session_status }, function(path)
    buffers.open(path)
  end)
end
--- Sort sessions by state: errors first, then running, then stopped, then
--- idle and done, with sessions awaiting a reply last.
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

-- Each open session has at most one parent: a fork points at `forked_from`,
-- a subagent at `subagent_parent` (both recorded as directories). The
-- buffer-var fallback covers a still-running child whose on-disk link has not
-- been read back yet.
local function open_owners(open_dirs)
  local owners = {}
  for _, b in pairs(open_dirs) do
    local e = frontmatter.end_line(b)
    local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(b, 0, e, false)) or nil
    local parent
    if fm then
      parent = (fm.forked_from and open_dirs[vim.fs.normalize(fm.forked_from)])
        or (fm.subagent_parent and open_dirs[vim.fs.normalize(fm.subagent_parent)])
    end
    parent = parent or vim.b[b].yap_subagent_parent
    if parent and parent ~= b then
      owners[b] = parent
    end
  end
  return owners
end

--- Every open yap session buffer, annotated with its live state and sorted by
--- state. Subagents and forks are indented under their parent. Tail viewers
--- are never here — use live() / <leader>l. Reachable as sessions("open").
open_sessions = function()
  local items = {}
  local open_dirs = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].yap then
      local path = vim.b[b].yap_path or vim.api.nvim_buf_get_name(b)
      if path ~= "" then
        open_dirs[vim.fs.normalize(vim.fn.fnamemodify(path, ":h"))] = b
      end
    end
  end
  local owners = open_owners(open_dirs)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local e = vim.b[b].yap and frontmatter.end_line(b)
    local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(b, 0, e, false)) or nil
    local parent = owners[b]
    if vim.b[b].yap then
      items[#items + 1] = {
        buf = b,
        text = session.live_label(b, parent ~= nil),
        path = parent and "" or vim.b[b].yap_project_cwd,
        state = picker.state(b),
        approval = pending_approvals[b] ~= nil,
        model = vim.b[b].yap_model,
        group_parent = (parent and vim.api.nvim_buf_is_valid(parent)) and parent or b,
        parent = parent,
      }
    end
  end
  if #items == 0 then
    vim.notify("yap: no open conversations", vim.log.levels.INFO)
    return
  end
  -- Sort roots by state; keep each child directly below its parent.
  local by_buf, children = {}, {}
  for _, item in ipairs(items) do
    by_buf[item.buf] = item
  end
  local roots = {}
  for _, item in ipairs(items) do
    local parent = item.parent
    if parent and by_buf[parent] then
      local row = vim.deepcopy(item)
      row.path = ""
      row.group_parent = parent
      row.text = session.live_label(item.buf, true)
      local siblings = children[parent] or {}
      siblings[#siblings + 1] = row
      children[parent] = siblings
    else
      if item.parent then
        item.path = vim.b[item.buf].yap_project_cwd
        item.text = session.live_label(item.buf, false)
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
  local function add(item, depth, ancestors)
    if ancestors[item.buf] then
      return
    end
    item.depth = depth
    ordered[#ordered + 1] = item
    local siblings = children[item.buf] or {}
    table.sort(siblings, function(a, b)
      return a.text < b.text
    end)
    ancestors[item.buf] = true
    for _, child in ipairs(siblings) do
      add(child, depth + 1, ancestors)
    end
    ancestors[item.buf] = nil
  end
  for _, item in ipairs(roots) do
    add(item, 0, {})
  end
  items = ordered
  -- The open tree conveys relationships through indentation, not status tags.
  -- The saved-session picker alone renders status glyphs.
  local projects = {}
  for _, item in ipairs(items) do
    projects[vim.b[item.buf].yap_project_cwd or ""] = true
  end
  local multiple_projects = vim.tbl_count(projects) > 1
  vim.ui.select(items, {
    prompt = "yap sessions",
    format_item = function(item)
      local suffix = multiple_projects and item.path and item.path ~= "" and (" (" .. item.path .. ")") or ""
      return string.rep("  ", item.depth) .. item.text .. suffix
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

return M
