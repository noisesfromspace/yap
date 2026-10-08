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
local drawer = require("harness.drawer")

local function harness()
  return require("harness")
end

local BOARD_NAME = "yap://guard"
local BOARD_HEIGHT = 12
local RECENT_MINUTES = 60 -- advisories newer than this stay in Open; older -> History

-- Highlight groups: structure is colored, content stays default. Linked
-- (not fixed colors) so every colorscheme renders them.
local HL = {
  header = "YapGuardHeader",
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
link(HL.header, "Title")
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

local function ensure_board()
  if board_buf and vim.api.nvim_buf_is_valid(board_buf) then
    return board_buf
  end
  board_buf = util.find_or_create_buffer(BOARD_NAME, false, true)
  vim.bo[board_buf].bufhidden = "hide"
  vim.bo[board_buf].modifiable = false
  vim.bo[board_buf].filetype = "yapguard"
  return board_buf
end

local function flat(s)
  return (s or ""):gsub("[\r\n]+", " ")
end

--- Decode a tool-call argument JSON into the primary target shown in a row:
--- the command (bash/ssh), path (write/edit/python file), or URL (curl/fetch).
local function decode_target(args)
  if not args or args == "" then
    return ""
  end
  local ok, a = pcall(vim.json.decode, args)
  if ok and type(a) == "table" then
    return flat(a.command or a.path or a.url or a.file or vim.inspect(a))
  end
  return flat(tostring(args))
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

-- ─── Rows ──────────────────────────────────────────────────────────────────

local function approval_row(buf, ev)
  return {
    kind = "approval",
    buf = buf,
    path = paths.session_path(buf) or vim.api.nvim_buf_get_name(buf),
    ordinal = nil, -- filled by approval_ordinal (scans the live audit log)
    session = harness().session_label(buf),
    ev = ev,
    tool = ev.tool or "tool",
    command = decode_target(ev.command),
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
    buf = nil,
    path = path,
    ordinal = ordinal,
    session = session_name,
    ev = ev,
    tool = ev.name or "tool",
    command = decode_target(call and call.args),
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
    buf = nil,
    path = path,
    ordinal = ordinal,
    session = session_name,
    ev = ev,
    tool = req.tool or "tool",
    command = decode_target(req.command),
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
    if minutes_ago(a.ts) <= RECENT_MINUTES then
      open_rows[#open_rows + 1] = a
    else
      history_rows[#history_rows + 1] = a
    end
  end
  for _, r in ipairs(resolved) do
    history_rows[#history_rows + 1] = r
  end

  return {
    { title = "Open", rows = open_rows },
    { title = "History", rows = history_rows },
  }
end

-- ─── Rendering ─────────────────────────────────────────────────────────────

local function cell(s, width)
  s = s or ""
  if #s > width then
    s = s:sub(1, width)
  end
  return s .. string.rep(" ", width - #s)
end

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
  if row.kind == "approval" and cat == "" and not row.p_alert then
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

local function summary_segments(row)
  local glyph, glyph_hl = row_glyph(row)
  local badge, badge_hl = severity_badge(row)
  local tool = (row.tool or "?")
  if #tool > 8 then
    tool = tool:sub(1, 8)
  end
  local cmd = (row.command or ""):gsub("%s+", " ")
  if #cmd > 40 then
    cmd = cmd:sub(1, 37) .. "…"
  end
  local p = row.p_alert
  local p_str = p and ("%.2f"):format(p):sub(2) or "—"
  return {
    { text = "  " },
    { text = glyph, hl = glyph_hl },
    { text = "  " },
    { text = cell(tool, 8) },
    { text = " " },
    { text = cell(cmd, 40) },
    { text = " " },
    { text = cell(badge, 12), hl = badge_hl },
    { text = " " },
    { text = cell(p_str, 5), hl = badge_hl },
    { text = " " },
    { text = cell(age(row.ts), 6), hl = HL.meta },
  }
end

local function detail_lines(row)
  local out = {}
  local function add(s)
    out[#out + 1] = s
  end
  add("   command    " .. (row.command ~= "" and flat(row.command) or "—"))
  add("   reason     " .. (row.reason ~= "" and flat(row.reason) or "—"))
  if row.severity then
    local sev = string.format("%.1f/3", row.severity)
    local conf = row.confidence and string.format(" · %.0f%% confident", row.confidence * 100) or ""
    local cat = row.severity_category ~= "" and row.severity_category or "?"
    add("   severity   " .. cat .. " · " .. sev .. conf)
  elseif row.kind == "approval" then
    add("   severity   always (no model consulted)")
  end
  if row.severity_breakdown ~= "" then
    add("   breakdown  " .. row.severity_breakdown)
  end
  local when = age(row.ts)
  add("   session    " .. flat(row.session) .. (row.kind == "approval" and (when ~= "" and (" · parked " .. when) or "") or ""))
  if row.context ~= "" then
    add("   context")
    for _, l in ipairs(vim.split(row.context, "\n", { plain = true })) do
      add("     " .. l)
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

  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      highlights[#highlights + 1] = { #lines - 1, hl, 0, #text }
    end
  end

  local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  add(("Guard Board · %s"):format(project), HL.header)
  add(("  Open %d · History %d"):format(#open_rows, #history_rows), HL.meta)

  local function emit_section(section)
    add("")
    add(("▸ %s (%d)"):format(section.title, #section.rows), HL.section)
    for _, row in ipairs(section.rows) do
      local start = #lines + 1 -- 1-based line of the summary (fold start)
      local segs = summary_segments(row)
      local text = {}
      local col = 0
      for _, seg in ipairs(segs) do
        text[#text + 1] = seg.text
        if seg.hl then
          highlights[#highlights + 1] = { start - 1, seg.hl, col, col + #seg.text }
        end
        col = col + #seg.text
      end
      lines[#lines + 1] = table.concat(text)
      local detail = detail_lines(row)
      for _, d in ipairs(detail) do
        lines[#lines + 1] = d
      end
      folds[#folds + 1] = { start, start + #detail }
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
  return folds
end

--- Apply manual per-row folds to every window showing the board, collapsing
--- each row to its summary line (the foldtext) so the queue stays scannable.
local function apply_folds(buf, folds)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.wo.foldmethod = "manual"
        vim.wo.foldminlines = 0
        vim.wo.foldtext = "v:lua.require'harness.guard'.foldtext()"
        vim.cmd("normal! zE")
        for _, f in ipairs(folds) do
          vim.cmd(("%d,%dfold"):format(f[1], f[2]))
          vim.cmd(("%dfoldclose"):format(f[1]))
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
    "# " .. title,
    "",
    ("**%s** · %s"):format(row.tool, session),
    "",
    "```bash",
    cmd ~= "" and cmd or "—",
    "```",
    "",
  }
  if row.p_alert then
    out[#out + 1] = ("`P(harmful)=%.2f`  `severity=%s(%.1f)`  `conf=%.0f%%`"):format(
      row.p_alert,
      row.severity_category ~= "" and row.severity_category or "?",
      row.severity or 0,
      (row.confidence or 0) * 100
    )
  elseif is_approval then
    out[#out + 1] = "`always approval (no model consulted)`"
  end
  out[#out + 1] = ""
  out[#out + 1] = "## Actions"
  if is_approval then
    out[#out + 1] = "- `r` **Run** — approve this call"
    out[#out + 1] = "- `x` **Deny** — reject"
  end
  out[#out + 1] = "- `i` **Inspect** — open the audit entry"
  out[#out + 1] = is_approval and "- `q` **Defer** — leave parked" or "- `q` **Dismiss**"
  return out
end

local function open_transient(row)
  local content = transient_content(row)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "markdown" -- touchup renders the markdown markup
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
    vim.cmd("normal! za")
  end
  vim.keymap.set("n", "za", toggle_row, { buffer = buf, silent = true, desc = "yap: expand/collapse guard row" })
  vim.keymap.set("n", "<Tab>", toggle_row, { buffer = buf, silent = true, desc = "yap: expand/collapse guard row" })
  vim.keymap.set("n", "]c", function()
    jump_section(1)
  end, { buffer = buf, silent = true, desc = "yap: next guard section" })
  vim.keymap.set("n", "[c", function()
    jump_section(-1)
  end, { buffer = buf, silent = true, desc = "yap: previous guard section" })
  vim.keymap.set("n", "<CR>", function()
    local row = vim.b[buf].yap_guard_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if row then
      open_transient(row)
    end
  end, { buffer = buf, silent = true, desc = "yap: act on guard row" })
end

--- Open (or focus) the board, or close it when already open. The board is a
--- global bottom drawer anchored to the window it was toggled from.
function M.toggle()
  local buf = ensure_board()
  if #vim.fn.win_findbuf(buf) > 0 then
    drawer.toggle(vim.api.nvim_get_current_buf(), buf, BOARD_HEIGHT)
    return
  end
  local folds = render()
  install_keymaps(buf)
  if not drawer.toggle(vim.api.nvim_get_current_buf(), buf, BOARD_HEIGHT) then
    return
  end
  apply_folds(buf, folds)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

--- Re-render the board when an approval/advisory event changes the open set,
--- but only while it is on screen (a hidden board re-renders on next open).
function M.touch()
  if not board_buf or not vim.api.nvim_buf_is_valid(board_buf) then
    return
  end
  if #vim.fn.win_findbuf(board_buf) > 0 then
    apply_folds(board_buf, render())
  end
end

return M
