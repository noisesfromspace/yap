-- The guard board (yap://guard): one read-only, global projection of the
-- static guard rules every tool declares in its source (bash's sudo/rm -rf,
-- ssh's always-approval, ...), with any parked approvals folded into the
-- same list so they can be answered in place. The rules come from `yap guard`
-- (a compiled-in listing), so adding a rule to a tool's source file is all it
-- takes for it to show up here. It opens as the same bottom drawer as the
-- live tool tail; actions are direct keys on the cursor row.

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

-- Highlight groups: structure is colored, content stays default. Linked
-- (not fixed colors) so every colorscheme renders them.
local HL = {
  approval = "YapGuardApproval",
  rule = "YapGuardRule",
  always = "YapGuardAlways",
  meta = "YapGuardMeta",
  hint = "YapGuardHint",
  tool = "YapGuardTool",
  command = "YapGuardCommand",
}
view.link(HL.approval, "DiagnosticWarn")
view.link(HL.rule, "Comment")
view.link(HL.always, "DiagnosticError")
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

-- The compiled-in static rules, cached once fetched: they only change when
-- the binary is rebuilt. A failure is not cached, so a later open retries
-- instead of pinning an empty board for the session.
local rules_cache

local function load_rules()
  if rules_cache then
    return rules_cache
  end
  -- With a list argument, system() raises E475 when the binary is not
  -- executable (unlike the string form, which reports shell_error). pcall
  -- keeps the board usable: with no rules it still lists parked approvals.
  local ok, out = pcall(vim.fn.system, { harness().config.bin, "guard" })
  if not ok or vim.v.shell_error ~= 0 then
    return {}
  end
  local decoded_ok, decoded = pcall(vim.json.decode, out)
  if decoded_ok and type(decoded) == "table" then
    rules_cache = decoded
    return decoded
  end
  return {}
end

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

-- ─── Rows ──────────────────────────────────────────────────────────────────

local function approval_row(buf, ev)
  return {
    kind = "approval",
    key = "approval:" .. (ev.id or ""),
    buf = buf,
    path = paths.session_path(buf) or vim.api.nvim_buf_get_name(buf),
    session = harness().session_label(buf),
    ev = ev,
    call = nil, -- filled below: the { id, occurrence } to focus
    tool = ev.tool or "tool",
    raw_command = decode_raw(ev.command),
    reason = ev.reason or "",
    ts = ev.ts or "",
  }
end

--- The tool call that triggered a live parked approval — { id, occurrence } —
--- so Inspect can focus the session's matching tool region.
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

local function rule_row(r)
  return {
    kind = "rule",
    key = "rule:" .. r.tool .. ":" .. r.name,
    buf = nil,
    tool = r.tool or "tool",
    name = r.name or "",
    always = r.always == true,
    raw_command = "",
    reason = "",
    ts = "",
  }
end

--- Build the single ordered row list: parked approvals first (actionable),
--- then the static rules (reference). Rules come sorted from `yap guard`.
local function build_rows()
  local approvals = {}
  for owner, ev in pairs(state.pending_approvals) do
    if vim.api.nvim_buf_is_valid(owner) then
      local row = approval_row(owner, ev)
      row.call = approval_call(owner, ev)
      approvals[#approvals + 1] = row
    end
  end
  table.sort(approvals, function(a, b)
    return (a.ts or "") > (b.ts or "")
  end)

  local rows = approvals
  local approval_count = #approvals
  for _, r in ipairs(load_rules()) do
    rows[#rows + 1] = rule_row(r)
  end
  return rows, approval_count
end

-- ─── Rendering ─────────────────────────────────────────────────────────────

local function summary_segments(row)
  if row.kind == "approval" then
    local reason = view.clip(row.reason, 62)
    if reason == "" then
      reason = "approval"
    end
    local when = age(row.ts)
    return {
      { text = " " },
      { text = harness().config.icons.approval, hl = HL.approval },
      { text = "  " },
      { text = reason, hl = HL.approval },
      { text = when ~= "" and ("  " .. when) or "", hl = HL.meta },
    }
  end
  local name = row.name ~= "" and row.name or "rule"
  if row.always then
    name = name .. " (always)"
  end
  return {
    { text = " " },
    { text = "·", hl = HL.rule },
    { text = "  " },
    { text = row.tool, hl = HL.tool },
    { text = " · " },
    { text = name, hl = row.always and HL.always or HL.rule },
  }
end

--- One detail line: an indented, width-aligned label (dim) plus the value.
local LABEL_W = 12

local function kv(label, value, value_hl)
  local segs = {
    { text = "    " },
    { text = label, hl = HL.meta },
  }
  local pad = LABEL_W - vim.fn.strdisplaywidth(label)
  if pad > 0 then
    segs[#segs + 1] = { text = string.rep(" ", pad) }
  end
  segs[#segs + 1] = { text = value, hl = value_hl }
  return segs
end

local function detail_lines(row)
  if row.kind == "rule" then
    if row.always then
      return { kv("always", "pauses every call for approval", HL.always) }
    end
    return {}
  end

  local out = {}
  out[#out + 1] = { { text = "    " }, { text = row.tool or "?", hl = HL.tool } }
  if (row.raw_command or "") ~= "" then
    for _, l in ipairs(view.shell_lines(row.raw_command, "  ")) do
      out[#out + 1] = { { text = "      " }, { text = l, hl = HL.command } }
    end
  end
  local when = age(row.ts)
  local sess = flat(row.session)
  if when ~= "" then
    sess = sess .. " · parked " .. when
  end
  out[#out + 1] = kv("session", sess, HL.meta)
  return out
end

--- Rebuild the board buffer from live approvals + the compiled-in rules.
local function render()
  local buf = ensure_board()
  local rows, approval_count = build_rows()

  local lines = {}
  local highlights = {}
  local folds = {}
  local row_map = {}
  local key_lines = {}
  local first_row_line

  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      highlights[#highlights + 1] = { #lines - 1, hl, 0, #text }
    end
  end

  local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  local rule_count = #rows - approval_count
  local counts = ("Rules %d"):format(rule_count)
  if approval_count > 0 then
    counts = ("%s · Parked %d"):format(counts, approval_count)
  end
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

  add("")
  for _, row in ipairs(rows) do
    local start = #lines + 1
    if not first_row_line then
      first_row_line = start
    end
    emit_segments(summary_segments(row))
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
  add("")
  add("a auto-accept · r/x run·deny · i inspect · za expand · q close", HL.hint)

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
--- with `vim.NIL` filling the gaps (header/blank lines), so reads must treat
--- `vim.NIL` as "no row here".
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
  if row.kind == "approval" then
    harness().reveal_call(row.path, row.call)
  end
end

-- ─── Board lifecycle ───────────────────────────────────────────────────────

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

--- Re-render the board when an approval event changes the open set, but only
--- while it is on screen (a hidden board re-renders on next open). The cursor
--- and expanded rows survive the refresh.
function M.touch()
  if not board_buf or not vim.api.nvim_buf_is_valid(board_buf) then
    return
  end
  local wins = vim.fn.win_findbuf(board_buf)
  if #wins == 0 then
    return
  end
  local win = wins[1]
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local row = row_at(board_buf, cur)
  local key = row and row.key
  local result = render()
  apply_folds(board_buf, result)
  local line = (key and result.key_lines[key]) or result.first_row_line or 1
  vim.api.nvim_win_set_cursor(win, { line, 0 })
end

return M
