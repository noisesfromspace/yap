-- The guard board (yap://guard): one read-only, global projection of every
-- parked approval and recent advisory, plus resolved history. It merges the
-- old :YapApproval and :YapAlerts pickers into a single re-enterable buffer
-- modeled on the audit view (a projection rebuilt from events) and on
-- Neogit/Magit's "status buffer + transient" split: the board is where you
-- look, a per-row floating popup is where you act.
--
-- Two sections, newest/open first:
--   Open     parked approvals (live, cross-project) + recent advisories
--   History  resolved approvals (granted/denied/timed-out) + older advisories
--
-- Rows are one scannable line, collapsed by default; `za` expands a row to
-- its full context (command, reason, severity breakdown, triggering
-- transcript). The trust ledger (guard.json) is intentionally NOT read or
-- written yet — the surface ships first, `always` rules land later.

local M = {}

local state = require("harness.state")
local paths = require("harness.path")
local util = require("harness.util")
local view = require("harness.view")

local function harness()
  return require("harness")
end

local BOARD_NAME = "yap://guard"
local BOARD_WIDTH = 88 -- vertical split width, capped to the screen
local RECENT_MINUTES = 15   -- advisories newer than this stay in Open
local HISTORY_MINUTES = 180 -- History drops rows older than this

-- Highlight groups: structure is colored, content stays default. Linked
-- (not fixed colors) so every colorscheme renders them.
local HL = {
  section = "YapGuardSection",
  approval = "YapGuardApproval",
  advisory = "YapGuardAdvisory",
  granted = "YapGuardGranted",
  denied = "YapGuardDenied",
  destructive = "YapGuardDestructive",
  reversible = "YapGuardReversible",
  benign = "YapGuardBenign",
  meta = "YapGuardMeta",
  hint = "YapGuardHint",
}
local function link(name, to)
  vim.api.nvim_set_hl(0, name, { link = to, default = true })
end
link(HL.section, "MoreMsg")
link(HL.approval, "DiagnosticWarn")
link(HL.advisory, "Comment")
link(HL.granted, "DiagnosticOk")
link(HL.denied, "DiagnosticError")
link(HL.destructive, "DiagnosticError")
link(HL.reversible, "DiagnosticWarn")
link(HL.benign, "Comment")
link(HL.meta, "Comment")
link(HL.hint, "Comment")

local ns = vim.api.nvim_create_namespace("yap.guard.hl")

-- The one global board buffer, created lazily.
local board_buf

-- The session window the board was toggled from, so closing it returns the
-- cursor there (never stranded on a dead window).
local board_anchor

local function ensure_board()
  if board_buf and vim.api.nvim_buf_is_valid(board_buf) then
    return board_buf
  end
  board_buf = util.find_or_create_buffer(BOARD_NAME, false, true)
  vim.bo[board_buf].bufhidden = "hide"
  vim.bo[board_buf].modifiable = false
  vim.bo[board_buf].filetype = "markdown" -- touchup/treesitter render the markdown
  return board_buf
end

local flat = view.flat

--- Decode a tool-call argument JSON into the primary target, raw (newlines
--- and heredocs preserved) so the detail can break it at operators.
local function decode_raw(args)
  if not args or args == "" then
    return ""
  end
  local ok, a = pcall(vim.json.decode, args)
  if ok and type(a) == "table" then
    return a.command or a.path or a.url or a.file or vim.inspect(a)
  end
  return tostring(args)
end

--- The same target, flattened to one line (for the summary/transient).
local function decode_target(args)
  return flat(decode_raw(args))
end

--- Parse an ISO timestamp into os.time, or nil when unparseable.
local function ts_time(ts)
  local y, mo, d, h, mi, s = ts:match("(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
end

--- Human "how long ago" from an ISO timestamp; empty when unparseable.
local function age(ts)
  if not ts or ts == "" then
    return ""
  end
  local then_t = ts_time(ts)
  if not then_t then
    return ""
  end
  local diff = os.difftime(os.time(), then_t)
  if diff < 0 then
    diff = 0
  end
  if diff < 60 then
    return string.format("%ds", diff)
  end
  if diff < 3600 then
    return string.format("%dm", math.floor(diff / 60))
  end
  if diff < 86400 then
    return string.format("%dh%dm", math.floor(diff / 3600), math.floor(diff % 3600 / 60))
  end
  return string.format("%dd", math.floor(diff / 86400))
end

--- Minutes since an ISO timestamp; math.huge when unparseable (treated as old).
local function minutes_ago(ts)
  local then_t = ts_time(ts)
  if not then_t then
    return math.huge
  end
  return os.difftime(os.time(), then_t) / 60
end

local function num(v)
  return tonumber(v)
end

--- A decision metric is "present" only when positive. The deterministic
--- floor (rm -rf /, sudo, ...) and ssh never consult the model, so they emit
--- 0 for every field; 0 is truthy in Lua, so a bare `if row.p_alert` would
--- wrongly take the "has metrics" branch and render "0.0/3 · 0% confident".
local function has_metrics(row)
  return (row.p_alert or 0) > 0 or (row.severity or 0) > 0
end

-- ─── Rows ──────────────────────────────────────────────────────────────────

local function approval_row(buf, ev)
  return {
    kind = "approval",
    key = "approval:" .. (ev.id or ""),
    buf = buf,
    path = paths.session_path(buf) or vim.api.nvim_buf_get_name(buf),
    ordinal = nil, -- filled by approval_ordinal (scans the live audit log)
    session = harness().session_label(buf),
    ev = ev,
    tool = ev.tool or "tool",
    command = decode_target(ev.command),
    raw_command = decode_raw(ev.command),
    reason = ev.reason or "",
    p_alert = num(ev.p_alert),
    severity = num(ev.severity),
    confidence = num(ev.confidence),
    severity_category = ev.severity_category or "",
    severity_breakdown = ev.severity_breakdown or "",
    context = ev.context or "",
    ts = ev.ts or "",
  }
end

local function advisory_row(ev, session_name, path, ordinal, call)
  return {
    kind = "advisory",
    key = "advisory:" .. (ev.id or "") .. ":" .. (ev.ts or ""),
    buf = nil,
    path = path,
    ordinal = ordinal,
    session = session_name,
    ev = ev,
    tool = ev.name or "tool",
    command = decode_target(call and call.args),
    raw_command = decode_raw(call and call.args),
    reason = ev.reason or "",
    p_alert = num(ev.p_alert),
    severity = num(ev.severity),
    confidence = num(ev.confidence),
    severity_category = ev.severity_category or "",
    severity_breakdown = ev.severity_breakdown or "",
    context = ev.context or "",
    ts = ev.ts or "",
  }
end

local function resolved_row(ev, req, session_name, path, ordinal)
  local kind
  if ev.type == "approval_result" then
    kind = ev.approved and "granted" or "denied"
  else
    kind = "timeout"
  end
  req = req or {}
  return {
    kind = kind,
    key = "resolved:" .. (ev.id or "") .. ":" .. (ev.ts or ""),
    buf = nil,
    path = path,
    ordinal = ordinal,
    session = session_name,
    ev = ev,
    tool = req.tool or "tool",
    command = decode_target(req.command),
    raw_command = decode_raw(req.command),
    reason = req.reason or "",
    p_alert = num(req.p_alert),
    severity = num(req.severity),
    confidence = num(req.confidence),
    severity_category = req.severity_category or "",
    severity_breakdown = req.severity_breakdown or "",
    context = req.context or "",
    ts = ev.ts or "",
  }
end

-- The review-event ordinal of a live parked approval: its index among the
-- session's alert_advisory/approval_request entries, so Inspect can focus it.
local function approval_ordinal(buf, ev)
  local path = paths.audit_path(buf)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ordinal = 0
  for _, line in ipairs(vim.fn.readfile(path)) do
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == "table" and (entry.type == "alert_advisory" or entry.type == "approval_request") then
      ordinal = ordinal + 1
      if entry.type == "approval_request" and entry.id == ev.id and entry.ts == ev.ts then
        return ordinal
      end
    end
  end
  return nil
end

--- Scan the current project's audit logs for advisories and resolved
--- approvals. Returns (advisories, resolved), each a list of rows.
local function scan_project()
  local advisories, resolved = {}, {}
  local session_dir = paths.session_dir(vim.fn.getcwd())
  for _, log in ipairs(vim.fn.glob(session_dir .. "/*/*.jsonl", false, true)) do
    if vim.fn.filereadable(log) == 1 then
      local path = vim.fn.fnamemodify(log, ":h") .. "/session.md"
      local session_name = paths.session_name(path)
      local ordinal, calls, requests = 0, {}, {}
      for _, line in ipairs(vim.fn.readfile(log)) do
        if line ~= "" then
          local ok, ev = pcall(vim.json.decode, line)
          if ok and type(ev) == "table" then
            if ev.type == "tool_call" and ev.id then
              calls[ev.id] = ev
            elseif ev.type == "alert_advisory" then
              ordinal = ordinal + 1
              advisories[#advisories + 1] = advisory_row(ev, session_name, path, ordinal, calls[ev.id])
            elseif ev.type == "approval_request" and ev.id then
              ordinal = ordinal + 1
              requests[ev.id] = { ev = ev, ordinal = ordinal }
            elseif ev.type == "approval_result" or ev.type == "approval_timeout" then
              local req = requests[ev.id]
              resolved[#resolved + 1] = resolved_row(ev, req and req.ev, session_name, path, req and req.ordinal)
            end
          end
        end
      end
    end
  end
  return advisories, resolved
end

local function newest_first(a, b)
  return (a.ts or "") > (b.ts or "")
end

--- Build the two sections as an ordered list of { title, rows }.
local function build_sections()
  local approvals = {}
  for owner, ev in pairs(state.pending_approvals) do
    if vim.api.nvim_buf_is_valid(owner) then
      local row = approval_row(owner, ev)
      row.ordinal = approval_ordinal(owner, ev)
      approvals[#approvals + 1] = row
    end
  end
  table.sort(approvals, newest_first)

  local advisories, resolved = scan_project()
  table.sort(advisories, newest_first)
  table.sort(resolved, newest_first)

  local open_rows = approvals
  local history_rows = {}
  for _, a in ipairs(advisories) do
    local ago = minutes_ago(a.ts)
    if ago <= RECENT_MINUTES then
      open_rows[#open_rows + 1] = a
    elseif ago <= HISTORY_MINUTES then
      history_rows[#history_rows + 1] = a
    end
  end
  for _, r in ipairs(resolved) do
    if minutes_ago(r.ts) <= HISTORY_MINUTES then
      history_rows[#history_rows + 1] = r
    end
  end

  return {
    { title = "Open", rows = open_rows },
    { title = "History", rows = history_rows },
  }
end

-- ─── Rendering ─────────────────────────────────────────────────────────────

local function row_glyph(row)
  local icons = harness().config.icons
  if row.kind == "approval" then
    return icons.approval, HL.approval
  elseif row.kind == "advisory" then
    return "!", HL.advisory
  elseif row.kind == "granted" then
    return icons.done, HL.granted
  else
    return "✗", HL.denied
  end
end

local function severity_badge(row)
  local cat = row.severity_category
  if row.kind == "approval" and not has_metrics(row) then
    return "always", HL.destructive
  end
  if cat == "destructive" or cat == "exfiltration" then
    return cat, HL.destructive
  elseif cat == "reversible" then
    return cat, HL.reversible
  elseif cat == "benign" then
    return cat, HL.benign
  end
  return "—", HL.meta
end

--- The one-line fold title: a glyph, the reason (the most human-meaningful
--- part of an event), and the age. The command, severity numbers and context
--- live in the expanded detail below, so the collapsed board is scannable
--- and the fold bar reads as a proper title rather than a crammed column grid.
local function title_segments(row)
  local glyph, glyph_hl = row_glyph(row)
  local _, badge_hl = severity_badge(row)
  local reason = flat(row.reason)
  if reason == "" then
    reason = row.kind == "advisory" and "advisory" or "approval"
  end
  if #reason > 64 then
    reason = reason:sub(1, 61) .. "…"
  end
  local when = age(row.ts)
  return {
    { text = " " },
    { text = glyph, hl = glyph_hl },
    { text = "  " },
    { text = reason, hl = badge_hl },
    { text = when ~= "" and ("  " .. when) or "", hl = HL.meta },
  }
end

--- The expanded detail, rendered as markdown (the board buffer is filetype
--- markdown): the command in a ```bash fence broken at operators, metrics as
--- a bullet list, and the triggering transcript as raw markdown so touchup
--- colors its # @user / # @assistant headings like the session buffer.
--- Returns a list of plain lines.
local function detail_lines(row)
  local out = {}
  out[#out + 1] = ("**%s**"):format(row.tool or "?")
  out[#out + 1] = "```bash"
  for _, l in ipairs(view.shell_lines(row.raw_command or "", "  ")) do
    out[#out + 1] = l
  end
  out[#out + 1] = "```"

  if has_metrics(row) then
    local parts = {}
    local cat = row.severity_category ~= "" and row.severity_category or "?"
    parts[#parts + 1] = cat
    parts[#parts + 1] = string.format("severity %.1f/3", row.severity or 0)
    if (row.p_alert or 0) > 0 then
      parts[#parts + 1] = string.format("P(harmful)=%.2f", row.p_alert)
    end
    if (row.confidence or 0) > 0 then
      parts[#parts + 1] = string.format("%.0f%% confident", row.confidence * 100)
    end
    out[#out + 1] = "- **severity** " .. table.concat(parts, " · ")
  elseif row.kind == "approval" then
    out[#out + 1] = "- **severity** always (no model consulted)"
  end
  if row.severity_breakdown ~= "" then
    out[#out + 1] = "- **breakdown** " .. row.severity_breakdown
  end
  local when = age(row.ts)
  local sess = flat(row.session)
  if row.kind == "approval" and when ~= "" then
    sess = sess .. " · parked " .. when
  end
  out[#out + 1] = "- **session** " .. sess

  if row.context ~= "" then
    out[#out + 1] = ""
    out[#out + 1] = "**context**"
    out[#out + 1] = ""
    local clines = vim.split(row.context, "\n", { plain = true })
    for i, l in ipairs(clines) do
      if i > 6 then
        out[#out + 1] = "…"
        break
      end
      out[#out + 1] = l
    end
  end
  return out
end

--- Rebuild the board buffer from live approvals + the project's audit logs.
local function render()
  local buf = ensure_board()
  local sections = build_sections()
  local open_rows = sections[1].rows
  local history_rows = sections[2].rows

  local lines = {}
  local highlights = {}
  local folds = {}
  local row_map = {}
  local key_lines = {} -- row key -> first summary line (for cursor restore)
  local first_open_line

  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      highlights[#highlights + 1] = { #lines - 1, hl, 0, #text }
    end
  end

  local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  local hdr = view.header_lines(
    ("Guard Board · %s"):format(project),
    ("Open %d · History %d"):format(#open_rows, #history_rows)
  )
  add(hdr[1], view.hl.header)
  add(hdr[2], view.hl.meta)

  local function emit_segments(segs)
    local line = #lines -- 0-based index of the line about to be appended
    local text = {}
    local col = 0
    for _, seg in ipairs(segs) do
      text[#text + 1] = seg.text
      if seg.hl then
        highlights[#highlights + 1] = { line, seg.hl, col, col + #seg.text }
      end
      col = col + #seg.text
    end
    lines[#lines + 1] = table.concat(text)
  end

  local function emit_section(section)
    add("")
    add(("▸ %s (%d)"):format(section.title, #section.rows), HL.section)
    for _, row in ipairs(section.rows) do
      local start = #lines + 1 -- 1-based line of the summary (fold start)
      if section.title == "Open" and not first_open_line then
        first_open_line = start
      end
      emit_segments(title_segments(row))
      local detail = detail_lines(row)
      for _, d in ipairs(detail) do
        add(d)
      end
      folds[#folds + 1] = { start, start + #detail, row.key }
      key_lines[row.key] = start
      for ln = start, start + #detail do
        row_map[ln] = row
      end
    end
  end

  emit_section(sections[1])
  emit_section(sections[2])
  add("")
  add("<CR> act · za expand · [c/]c section · q close", HL.hint)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, ns, h[2], h[1], h[3], h[4])
  end
  vim.bo[buf].modifiable = false

  vim.b[buf].yap_guard_rows = row_map
  return { folds = folds, first_open_line = first_open_line, key_lines = key_lines }
end

--- The row under a board buffer line, or nil. `row_map` is a sparse map keyed
--- by line number; storing it in `vim.b` makes Neovim convert it to a list
--- with `vim.NIL` filling the gaps (header/section/blank lines), so reads
--- must treat `vim.NIL` as "no row here".
local function row_at(buf, line)
  local rows = vim.b[buf].yap_guard_rows
  local row = type(rows) == "table" and rows[line] or nil
  if row == vim.NIL then
    return nil
  end
  return row
end

-- Rows the user has expanded; preserved across re-renders so a live update
-- never collapses what they were reading.
local expanded = {}

--- Apply manual per-row folds to every window showing the board, collapsing
--- each row to its summary line (the foldtext) so the queue stays scannable.
--- Rows in `expanded` stay open.
local function apply_folds(buf, result)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.wo.foldmethod = "manual"
        vim.wo.foldminlines = 0
        vim.wo.foldtext = "v:lua.require'harness.guard'.foldtext()"
        vim.cmd("normal! zE")
        for _, f in ipairs(result.folds) do
          vim.cmd(("%d,%dfold"):format(f[1], f[2]))
          if expanded[f[3]] then
            vim.cmd(("%dfoldopen"):format(f[1]))
          else
            vim.cmd(("%dfoldclose"):format(f[1]))
          end
        end
      end)
    end
  end
end

function M.foldtext()
  return vim.fn.getline(vim.v.foldstart)
end

-- ─── Transient (the per-row action popup) ──────────────────────────────────

local function transient_content(row)
  local is_approval = row.kind == "approval"
  local title = is_approval and "Approval required"
    or (row.kind == "advisory" and "Advisory" or "History")
  local session = flat(row.session)
  if #session > 30 then
    session = session:sub(1, 27) .. "…"
  end
  local cmd = flat(row.command)
  if #cmd > 60 then
    cmd = cmd:sub(1, 57) .. "…"
  end

  local out = {
    (" %s · %s · %s"):format(row.tool, session, title),
    " $ " .. (cmd ~= "" and cmd or "—"),
  }
  if has_metrics(row) then
    out[#out + 1] = (" P(harmful)=%.2f  severity=%s(%.1f)  conf=%.0f%%"):format(
      row.p_alert,
      row.severity_category ~= "" and row.severity_category or "?",
      row.severity or 0,
      (row.confidence or 0) * 100
    )
  elseif is_approval then
    out[#out + 1] = " always approval (no model consulted)"
  end
  out[#out + 1] = ""
  out[#out + 1] = " Actions"
  if is_approval then
    out[#out + 1] = "  r  Run — approve this call"
    out[#out + 1] = "  x  Deny — reject"
  end
  out[#out + 1] = "  i  Inspect — open the audit entry"
  out[#out + 1] = is_approval and "  q  Defer — leave parked" or "  q  Dismiss"
  return out
end

local function open_transient(row)
  local content = transient_content(row)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "yapguard"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
  vim.bo[bufnr].modifiable = false

  -- Fit the window to its (bounded) content: sizing by a fraction of the
  -- screen hid the action keys whenever the command wrapped. Clip the
  -- command and disable wrap instead, so the menu always fits.
  local height = math.min(#content, math.max(1, vim.o.lines - 2))
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    anchor = "SW",
    width = vim.o.columns,
    height = height,
    col = 0,
    row = vim.o.lines - 1,
    style = "minimal",
    border = { "─", "─", "─", "", "", "", "", "" },
  })
  vim.wo[win].wrap = false

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function answer(approved)
    close()
    harness().answer_approval(row.buf, approved)
  end

  local function inspect()
    close()
    harness().reveal_audit(row.path, row.ordinal)
  end

  if row.kind == "approval" then
    vim.keymap.set("n", "r", function()
      answer(true)
    end, { buffer = bufnr, nowait = true, silent = true })
    vim.keymap.set("n", "x", function()
      answer(false)
    end, { buffer = bufnr, nowait = true, silent = true })
  end
  vim.keymap.set("n", "i", inspect, { buffer = bufnr, nowait = true, silent = true })
  for _, key in ipairs({ "q", "<Esc>", "<C-c>" }) do
    vim.keymap.set("n", key, close, { buffer = bufnr, nowait = true, silent = true })
  end
end

-- ─── Board lifecycle ───────────────────────────────────────────────────────

local function jump_section(dir)
  vim.fn.search("^▸ ", dir > 0 and "W" or "Wb")
end

local function install_keymaps(buf)
  vim.keymap.set("n", "q", function()
    M.toggle()
  end, { buffer = buf, silent = true, desc = "yap: close guard board" })
  local function toggle_row()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local row = row_at(buf, line)
    if not row then
      return -- header/blank/hint lines aren't folds; za would raise E490
    end
    vim.cmd("normal! za")
    if vim.fn.foldclosed(line) == -1 then
      expanded[row.key] = true
    else
      expanded[row.key] = nil
    end
  end
  vim.keymap.set("n", "za", toggle_row, { buffer = buf, silent = true, desc = "yap: expand/collapse guard row" })
  vim.keymap.set("n", "<Tab>", toggle_row, { buffer = buf, silent = true, desc = "yap: expand/collapse guard row" })
  -- A click on a closed row opens it; open content keeps native mouse
  -- behavior (matches the session buffer and the audit view).
  vim.keymap.set("n", "<LeftMouse>", view.mouse_fold, {
    buffer = buf, expr = true, silent = true, desc = "yap: open guard row on click",
  })
  vim.keymap.set("n", "]c", function()
    jump_section(1)
  end, { buffer = buf, silent = true, desc = "yap: next guard section" })
  vim.keymap.set("n", "[c", function()
    jump_section(-1)
  end, { buffer = buf, silent = true, desc = "yap: previous guard section" })
  vim.keymap.set("n", "<CR>", function()
    local row = row_at(buf, vim.api.nvim_win_get_cursor(0)[1])
    if row then
      open_transient(row)
    end
  end, { buffer = buf, silent = true, desc = "yap: act on guard row" })
end

--- Open (or focus) the board, or close it when already open. The board is a
--- global vertical split anchored to the window it was toggled from, so it
--- opens beside the session (not below it) and closing returns the cursor.
function M.toggle()
  local buf = ensure_board()
  local wins = vim.fn.win_findbuf(buf)
  if #wins > 0 then
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        -- Closing the board when it is the tab's last window raises E444
        -- (:bd on the anchored session collapses its split, leaving the
        -- board alone). Close the tab instead, exactly like native :q on a
        -- last window.
        local tab = vim.api.nvim_win_get_tabpage(win)
        local normals = 0
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
          if vim.api.nvim_win_get_config(w).relative == "" then
            normals = normals + 1
          end
        end
        if normals == 1 then
          vim.cmd("q")
        else
          vim.api.nvim_win_close(win, true)
        end
      end
    end
    if board_anchor and vim.api.nvim_win_is_valid(board_anchor) then
      vim.api.nvim_set_current_win(board_anchor)
    end
    board_anchor = nil
    return
  end
  local result = render()
  install_keymaps(buf)

  -- Anchor to the window the user toggled from (their session window).
  board_anchor = vim.api.nvim_get_current_win()
  local width = math.min(BOARD_WIDTH, vim.o.columns - 1)
  vim.cmd(("vert belowright %dsplit"):format(width))
  vim.api.nvim_win_set_buf(0, buf)
  apply_folds(buf, result)
  -- Land on the first Open row, not the header: that row is the actionable one.
  vim.api.nvim_win_set_cursor(0, { result.first_open_line or 1, 0 })
end

--- Re-render the board when an approval/advisory event changes the open set,
--- but only while it is on screen (a hidden board re-renders on next open).
--- The cursor and expanded rows survive the refresh.
function M.touch()
  if not board_buf or not vim.api.nvim_buf_is_valid(board_buf) then
    return
  end
  local wins = vim.fn.win_findbuf(board_buf)
  if #wins == 0 then
    return
  end
  local win = wins[1]
  -- Read/write the BOARD window's cursor, not the current window: touch()
  -- runs from the session's event callback, where window 0 is the session.
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local row = row_at(board_buf, cur)
  local key = row and row.key
  local result = render()
  apply_folds(board_buf, result)
  local line = (key and result.key_lines[key]) or result.first_open_line or 1
  vim.api.nvim_win_set_cursor(win, { line, 0 })
end

return M
