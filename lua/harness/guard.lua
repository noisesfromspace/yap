-- The guard board (yap://guard): one read-only, global projection of every
-- parked approval and recent advisory, plus resolved history. It merges the
-- old :YapApproval and :YapAlerts pickers into a single re-enterable buffer
-- modeled on the live tool tail. It opens as the same bottom drawer as the
-- live tail; actions are direct keys on the cursor row.
--
-- Two sections, newest first:
--   Guard     every approval — parked (needs Run/Deny) and settled
--             (granted/denied/timed-out); the glyph shows the state
--   Advisory  advisories (calls that ran with a non-blocking warning)
--
-- Rows are one scannable line, collapsed by default; `za` expands a row to
-- its full context (command, reason, severity breakdown). guard.json stores
-- the project's clear watermark; `always` trust rules land later.

local M = {}

local state = require("harness.state")
local paths = require("harness.path")
local util = require("harness.util")
local view = require("harness.view")
local drawer = require("harness.drawer")

local function harness()
  return require("harness")
end

local BOARD_NAME = "yap://guard"
local MAX_SECTION_ROWS = 30 -- cap each section (Guard, Advisory) to 30 rows

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
  tool = "YapGuardTool",
  command = "YapGuardCommand",
}
view.link(HL.section, "MoreMsg")
view.link(HL.approval, "DiagnosticWarn")
view.link(HL.advisory, "Comment")
view.link(HL.granted, "DiagnosticOk")
view.link(HL.denied, "DiagnosticError")
view.link(HL.destructive, "DiagnosticError")
view.link(HL.reversible, "DiagnosticWarn")
view.link(HL.benign, "Comment")
view.link(HL.meta, "Comment")
view.link(HL.hint, "Comment")
view.link(HL.tool, "Title")
view.link(HL.command, "String")

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
  vim.bo[board_buf].filetype = "" -- plain text; rows carry their own highlights
  return board_buf
end

--- The board buffer, or nil before it is created (used to detect whether the
--- board is on screen without forcing it into existence).
function M.buf()
  if board_buf and vim.api.nvim_buf_is_valid(board_buf) then
    return board_buf
  end
  return nil
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

local function num(v)
  return tonumber(v)
end

--- A decision metric is "present" only when positive. The deterministic
--- floor (rm -rf /, sudo, ...) and ssh never consult the model, so they emit
--- 0 for every field; 0 is truthy in Lua, so a bare `if row.p_alert` would
--- wrongly take the "has metrics" branch and render "0.0/3 · 0% confident".
local function has_metrics(row)
  return (row.p_alert or 0) > 0 or (row.severity or 0) > 0 or (row.reveals_secret or 0) > 0
end

-- ─── Rows ──────────────────────────────────────────────────────────────────

local function approval_row(buf, ev)
  return {
    kind = "approval",
    key = "approval:" .. (ev.id or ""),
    buf = buf,
    path = paths.session_path(buf) or vim.api.nvim_buf_get_name(buf),
    call = nil, -- filled by approval_call: the { id, occurrence } to focus
    session = harness().session_label(buf),
    ev = ev,
    tool = ev.tool or "tool",
    raw_command = decode_raw(ev.command),
    reason = ev.reason or "",
    p_alert = num(ev.p_alert),
    severity = num(ev.severity),
    confidence = num(ev.confidence),
    reveals_secret = num(ev.reveals_secret),
    severity_category = ev.severity_category or "",
    severity_breakdown = ev.severity_breakdown or "",
    risk = ev.risk or "",
    ts = ev.ts or "",
  }
end

local function advisory_row(ev, session_name, path, call, call_ref)
  return {
    kind = "advisory",
    key = "advisory:" .. (ev.id or "") .. ":" .. (ev.ts or ""),
    buf = nil,
    path = path,
    call = call_ref, -- { id, occurrence } of the flagged tool call (or nil)
    session = session_name,
    ev = ev,
    tool = ev.name or "tool",
    raw_command = decode_raw(call and call.args),
    reason = ev.reason or "",
    p_alert = num(ev.p_alert),
    severity = num(ev.severity),
    confidence = num(ev.confidence),
    reveals_secret = num(ev.reveals_secret),
    severity_category = ev.severity_category or "",
    severity_breakdown = ev.severity_breakdown or "",
    risk = ev.risk or "",
    ts = ev.ts or "",
  }
end

local function resolved_row(ev, req, session_name, path, call_ref)
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
    call = call_ref, -- { id, occurrence } of the gated tool call (or nil)
    session = session_name,
    ev = ev,
    tool = req.tool or "tool",
    raw_command = decode_raw(req.command),
    reason = req.reason or "",
    p_alert = num(req.p_alert),
    severity = num(req.severity),
    confidence = num(req.confidence),
    reveals_secret = num(req.reveals_secret),
    severity_category = req.severity_category or "",
    severity_breakdown = req.severity_breakdown or "",
    risk = req.risk or "",
    ts = ev.ts or "",
  }
end

-- The tool call that triggered a live parked approval — { id, occurrence } —
-- so Inspect can focus the session's matching tool region.
local function approval_call(buf, ev)
  local path = paths.audit_path(buf)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local occurrences, last_call = {}, nil
  for _, line in ipairs(vim.fn.readfile(path)) do
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == "table" then
      if entry.type == "tool_call" and entry.id then
        occurrences[entry.id] = (occurrences[entry.id] or 0) + 1
        last_call = { id = entry.id, occurrence = occurrences[entry.id] }
      elseif entry.type == "approval_request" and entry.id == ev.id and entry.ts == ev.ts then
        return last_call
      end
    end
  end
end

-- The clear watermark lives in guard.json beside the project's session
-- directories. It is a project-scoped timestamp: advisory and resolved
-- approval events at or before it are hidden from the board, but stay in the
-- append-only audit log. Parked approvals are live state and are denied
-- directly by clear(), never filtered here.
local function guard_file()
  return paths.session_dir(vim.fn.getcwd()) .. "/guard.json"
end

local function read_cleared_time()
  local p = guard_file()
  if vim.fn.filereadable(p) ~= 1 then
    return nil
  end
  local ok, data = pcall(vim.json.decode, vim.fn.readfile(p)[1] or "")
  if ok and type(data) == "table" then
    return ts_time(data.cleared_ts or "")
  end
  return nil
end

local function write_cleared_time(ts)
  local p = guard_file()
  paths.ensure_session_dir(vim.fn.fnamemodify(p, ":h"))
  vim.fn.writefile({ vim.json.encode({ cleared_ts = ts }) }, p)
  vim.fn.setfperm(p, "rw-------")
end

local function is_cleared(ev, cleared)
  if not cleared then
    return false
  end
  local t = ts_time(ev.ts)
  return t ~= nil and t <= cleared
end

--- Scan the current project's audit logs for advisories and resolved
--- approvals. Returns (advisories, resolved), each a list of rows. Events at
--- or before `cleared` (an os.time) are skipped.
local function scan_project(cleared)
  local advisories, resolved = {}, {}
  local session_dir = paths.session_dir(vim.fn.getcwd())
  for _, log in ipairs(vim.fn.glob(session_dir .. "/*/*.jsonl", false, true)) do
    if vim.fn.filereadable(log) == 1 then
      local path = vim.fn.fnamemodify(log, ":h") .. "/session.md"
      local session_name = paths.session_name(path)
      local calls, occurrences, requests, last_call = {}, {}, {}, nil
      for _, line in ipairs(vim.fn.readfile(log)) do
        if line ~= "" then
          local ok, ev = pcall(vim.json.decode, line)
          if ok and type(ev) == "table" then
            if ev.type == "tool_call" and ev.id then
              occurrences[ev.id] = (occurrences[ev.id] or 0) + 1
              calls[ev.id] = ev
              last_call = { id = ev.id, occurrence = occurrences[ev.id] }
            elseif ev.type == "alert_advisory" then
              if not is_cleared(ev, cleared) then
                local call_ref = ev.id and occurrences[ev.id] and { id = ev.id, occurrence = occurrences[ev.id] } or nil
                advisories[#advisories + 1] = advisory_row(ev, session_name, path, calls[ev.id], call_ref)
              end
            elseif ev.type == "approval_request" and ev.id then
              requests[ev.id] = { ev = ev, call = last_call }
            elseif ev.type == "approval_result" or ev.type == "approval_timeout" then
              if not is_cleared(ev, cleared) then
                local req = requests[ev.id]
                resolved[#resolved + 1] = resolved_row(ev, req and req.ev, session_name, path, req and req.call)
              end
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

--- Cap a list to the newest `n` rows (rows are already sorted newest first).
local function cap(rows, n)
  if #rows <= n then
    return rows
  end
  local out = {}
  for i = 1, n do
    out[i] = rows[i]
  end
  return out
end

--- Build the two sections as an ordered list of { title, rows }.
local function build_sections()
  local approvals = {}
  for owner, ev in pairs(state.pending_approvals) do
    if vim.api.nvim_buf_is_valid(owner) then
      local row = approval_row(owner, ev)
      row.call = approval_call(owner, ev)
      approvals[#approvals + 1] = row
    end
  end

  local advisories, resolved = scan_project(read_cleared_time())
  table.sort(advisories, newest_first)
  table.sort(resolved, newest_first)

  -- Guard holds every approval — parked and settled — so a denied/timed-out
  -- approval stays visible beside the parked ones; the glyph states which.
  -- Parked approvals are the actionable rows (r/x act on them): cap only
  -- the settled history so a backlog of resolved rows can never push a
  -- pending approval off the board.
  local guard_rows = approvals
  for _, r in ipairs(cap(resolved, MAX_SECTION_ROWS)) do
    guard_rows[#guard_rows + 1] = r
  end
  table.sort(guard_rows, newest_first)

  -- Cap only the settled history (already done above): parked approvals are
  -- never capped away. Advisory keeps its own independent budget so a large
  -- Guard section cannot starve it to zero.
  return {
    { title = "Guard", rows = guard_rows },
    { title = "Advisory", rows = cap(advisories, MAX_SECTION_ROWS) },
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

local function severity_hl(row)
  local cat = row.severity_category
  if cat == "destructive" or cat == "exfiltration" then
    return HL.destructive
  elseif cat == "reversible" then
    return HL.reversible
  elseif cat == "benign" then
    return HL.benign
  end
  return HL.meta
end

local function severity_badge(row)
  if row.kind == "approval" and not has_metrics(row) then
    return "always", HL.destructive
  end
  local cat = row.severity_category
  if cat ~= "" then
    return cat, severity_hl(row)
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
  local reason = view.clip(row.reason, 62)
  if reason == "" then
    reason = row.kind == "advisory" and "advisory" or "approval"
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

--- Fallback for rows persisted before the risk phrase was emitted: derive it
--- from the dominant severity band, which older events still carry.
local RISK_LEVEL = { benign = "low", reversible = "moderate", destructive = "high", exfiltration = "critical" }
local RISK_PHRASE = { benign = "mostly benign", reversible = "likely reversible", destructive = "possible data loss", exfiltration = "possible exfiltration" }

local function risk_text(row)
  if row.risk ~= "" then
    return row.risk
  end
  local cat = row.severity_category or ""
  if RISK_LEVEL[cat] then
    return RISK_LEVEL[cat] .. " — " .. RISK_PHRASE[cat]
  end
  return ""
end

--- One detail metric line: an indented, width-aligned label (dim) followed by
--- the value and an optional plain-English explanation.
local LABEL_W = 12

local function kv(label, value, value_hl, explain)
  local segs = {
    { text = "    " },
    { text = label, hl = HL.meta },
  }
  local pad = LABEL_W - vim.fn.strdisplaywidth(label)
  if pad > 0 then
    segs[#segs + 1] = { text = string.rep(" ", pad) }
  end
  segs[#segs + 1] = { text = value, hl = value_hl }
  if explain and explain ~= "" then
    segs[#segs + 1] = { text = "  " .. explain, hl = HL.meta }
  end
  return segs
end

--- The expanded detail, rendered as plain text with per-segment highlights
--- (the board buffer is no longer markdown): the tool name, its command broken
--- at operators, and the decision metrics explained in words. Returns a list of
--- segment lists (one per line).
local function detail_lines(row)
  local out = {}
  out[#out + 1] = { { text = "    " }, { text = row.tool or "?", hl = HL.tool } }
  if (row.raw_command or "") ~= "" then
    for _, l in ipairs(view.shell_lines(row.raw_command, "  ")) do
      out[#out + 1] = { { text = "      " }, { text = l, hl = HL.command } }
    end
  end

  if has_metrics(row) then
    local risk = risk_text(row)
    if risk ~= "" then
      out[#out + 1] = kv("risk", risk, severity_hl(row))
    end
    if (row.reveals_secret or 0) > 0 then
      out[#out + 1] = kv("secret", string.format("%.0f%%", row.reveals_secret * 100), HL.destructive, "odds this reveals a live credential")
    end
    if (row.p_alert or 0) > 0 then
      out[#out + 1] = kv("harmful", string.format("%.0f%%", row.p_alert * 100), HL.meta, "odds this call causes real harm")
    end
    if (row.severity or 0) > 0 then
      out[#out + 1] = kv("severity", string.format("%.1f / 3", row.severity), HL.meta, "worst-harm score (0 benign → 3 exfiltration)")
    end
    if (row.confidence or 0) > 0 then
      out[#out + 1] = kv("confidence", string.format("%.0f%%", row.confidence * 100), HL.meta, "how sure the model is")
    end
    if row.severity_breakdown ~= "" then
      out[#out + 1] = kv("breakdown", row.severity_breakdown, HL.meta, "odds per outcome")
    end
  elseif row.kind == "approval" then
    out[#out + 1] = kv("risk", "always — no model consulted", HL.destructive)
  end

  local when = age(row.ts)
  local sess = flat(row.session)
  if row.kind == "approval" and when ~= "" then
    sess = sess .. " · parked " .. when
  end
  out[#out + 1] = kv("session", sess, HL.meta)

  return out
end

--- Rebuild the board buffer from live approvals + the project's audit logs.
local function render()
  local buf = ensure_board()
  local sections = build_sections()
  local guard_rows = sections[1].rows
  local advisory_rows = sections[2].rows

  local lines = {}
  local highlights = {}
  local folds = {}
  local row_map = {}
  local key_lines = {} -- row key -> first summary line (for cursor restore)
  local first_row_line

  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      highlights[#highlights + 1] = { #lines - 1, hl, 0, #text }
    end
  end

  local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  local counts = ("Guard %d · Advisory %d"):format(#guard_rows, #advisory_rows)
  if state.auto_accept then
    counts = counts .. " · auto-accept on"
  end
  local hdr = view.header_lines(("Guard Board · %s"):format(project), counts)
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
      if section.title == "Guard" and not first_row_line then
        first_row_line = start
      end
      emit_segments(title_segments(row))
      local detail = detail_lines(row)
      for _, segs in ipairs(detail) do
        emit_segments(segs)
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
  add("a auto-accept · r/x run·deny · i inspect · c clear · za expand · [c/]c section · q close", HL.hint)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, ns, h[2], h[1], h[3], h[4])
  end
  vim.bo[buf].modifiable = false

  vim.b[buf].yap_guard_rows = row_map
  return { folds = folds, first_row_line = first_row_line, key_lines = key_lines }
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

-- ─── Row actions ───────────────────────────────────────────────────────────
-- Shared by every row action below, so a shortcut on the cursor row
-- behaves exactly like answering directly.
local function approve_row(row)
  if row.kind == "approval" then
    harness().answer_approval(row.buf, true)
  end
end

local function deny_row(row)
  if row.kind == "approval" then
    harness().answer_approval(row.buf, false)
  end
end

local function inspect_row(row)
  harness().reveal_call(row.path, row.call)
end

-- ─── Board lifecycle ───────────────────────────────────────────────────────

local function jump_section(dir)
  vim.fn.search("^▸ ", dir > 0 and "W" or "Wb")
end

local function install_keymaps(buf)
  local cfg = harness().config
  vim.keymap.set("n", "q", function()
    M.toggle()
  end, { buffer = buf, silent = true, desc = "yap: close guard board" })
  if cfg.keymaps.live ~= "" then
    vim.keymap.set("n", cfg.keymaps.live, function()
      harness().live()
    end, { buffer = buf, silent = true, desc = "yap: toggle live tool output" })
  end
  if cfg.keymaps.guard ~= "" then
    vim.keymap.set("n", cfg.keymaps.guard, function()
      M.toggle()
    end, { buffer = buf, silent = true, desc = "yap: guard board" })
  end
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
  -- behavior (matches the session buffer).
  vim.keymap.set("n", "<LeftMouse>", view.mouse_fold, {
    buffer = buf, expr = true, silent = true, desc = "yap: open guard row on click",
  })
  vim.keymap.set("n", "]c", function()
    jump_section(1)
  end, { buffer = buf, silent = true, desc = "yap: next guard section" })
  vim.keymap.set("n", "[c", function()
    jump_section(-1)
  end, { buffer = buf, silent = true, desc = "yap: previous guard section" })

  -- Direct action keys on the cursor row: r/x run/deny an approval, i
  -- inspects any row.
  local function act(action)
    return function()
      local row = row_at(buf, vim.api.nvim_win_get_cursor(0)[1])
      if row then
        action(row)
      end
    end
  end
  vim.keymap.set("n", "r", act(approve_row), { buffer = buf, silent = true, desc = "yap: approve guard row" })
  vim.keymap.set("n", "x", act(deny_row), { buffer = buf, silent = true, desc = "yap: deny guard row" })
  vim.keymap.set("n", "i", act(inspect_row), { buffer = buf, silent = true, desc = "yap: inspect guard row" })
  vim.keymap.set("n", "a", function()
    M.toggle_auto_accept()
  end, { buffer = buf, silent = true, desc = "yap: toggle auto-accept" })
  -- `c` is board-wide, not a cursor-row action: deny every parked approval
  -- and clear advisories/settled history.
  vim.keymap.set("n", "c", function()
    M.clear()
  end, { buffer = buf, silent = true, desc = "yap: clear guard board" })

end

--- Open (or focus) the board, or close it when already open. The board is a
--- global bottom drawer anchored to the session it was toggled from, stacked
--- above that session's live tail when it is open (the canonical session →
--- guard → log order), otherwise directly below the session window. Closing
--- returns the cursor to the window it was toggled from.
function M.toggle()
  local buf = ensure_board()
  local cur = vim.api.nvim_get_current_buf()

  local owner = harness().session_of(cur)
  local split, anchor
  if owner then
    vim.b[buf].yap_owner = owner
    local tail = harness().tail_buffer(owner)
    local log_win = drawer.win_in_tab(tail, vim.api.nvim_get_current_tabpage())
    if log_win then
      split, anchor = "above", log_win
    else
      split, anchor = "below", drawer.owner_window(owner)
    end
  else
    split, anchor = "below", vim.api.nvim_get_current_win()
  end

  if not drawer.open_at(buf, drawer.half_screen(), nil, split, anchor) then
    return
  end
  local result = render()
  install_keymaps(buf)
  apply_folds(buf, result)
  -- Land on the first Guard row, not the header: that row is the actionable one.
  vim.api.nvim_win_set_cursor(0, { result.first_row_line or 1, 0 })
end

--- Toggle auto-accept: while on, incoming approval requests are answered Run
--- immediately, and any currently parked approvals are swept as Run too.
--- Session-lifetime only (never persisted).
function M.toggle_auto_accept()
  state.auto_accept = not state.auto_accept
  if state.auto_accept then
    local owners = {}
    for owner in pairs(state.pending_approvals) do
      if vim.api.nvim_buf_is_valid(owner) then
        owners[#owners + 1] = owner
      end
    end
    for _, owner in ipairs(owners) do
      harness().answer_approval(owner, true)
    end
  end
  M.touch()
end

--- Clear every item on the board: deny each parked approval (the safe,
--- non-running answer that releases its turn) and hide all advisories and
--- settled history at or before now. The audit log is left intact; the
--- project watermark makes the clear persist across reopens.
function M.clear()
  local owners = {}
  for owner in pairs(state.pending_approvals) do
    if vim.api.nvim_buf_is_valid(owner) then
      owners[#owners + 1] = owner
    end
  end
  for _, owner in ipairs(owners) do
    harness().answer_approval(owner, false)
  end
  write_cleared_time(os.date("%Y-%m-%dT%H:%M:%S"))
  M.touch()
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
  local line = (key and result.key_lines[key]) or result.first_row_line or 1
  vim.api.nvim_win_set_cursor(win, { line, 0 })
end

return M
