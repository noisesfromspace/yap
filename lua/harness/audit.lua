-- The session's audit log, rendered live.
--
-- The live view (:YapLive) is a human-readable, highlighted, folded
-- projection of the JSON Lines audit log, rebuilt from it on reopen. This
-- module owns the rendering; the buffer lifecycle (create, replay on
-- reopen, the audit-log write) stays in harness.

local M = {}

local paths = require("harness.path")
local util = require("harness.util")
local state = require("harness.state")

-- Highlight groups: structure is colored, content stays default so
-- streamed/returned text reads as plain text. Links (not fixed colors) so
-- every colorscheme renders them; `default` keeps user overrides.
local HL = {
  turn = "YapAuditTurn",
  command = "YapAuditCommand",
  tool = "YapAuditTool",
  meta = "YapAuditMeta",
  warn = "YapAuditWarn",
}
local function link(name, to)
  vim.api.nvim_set_hl(0, name, { link = to, default = true })
end
link(HL.turn, "Title")
link(HL.command, "Function")
link(HL.tool, "Type")
link(HL.meta, "Comment")
link(HL.warn, "WarningMsg")

-- Namespace for the live view's per-line highlights.
local ns = vim.api.nvim_create_namespace("yap.audit.hl")

-- A turn journal line (the live view's section header):
-- `# <ts> turn: <in> in · <out> out · <s>s`.
local TURN = "^# %d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d turn:"

-- An append can invalidate a native manual fold before turn_end projects the
-- next one. Remember the window's choices while its old folds still exist.
local turn_open = {} -- win -> { [header line] = open }
local function headers(buf)
  local result = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match(TURN) then
      result[#result + 1] = i
    end
  end
  return result
end

local function remember(buf)
  local ends = headers(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_win_call(win, function()
      local open = turn_open[win] or {}
      for _, finish in ipairs(ends) do
        if vim.fn.foldlevel(finish) > 0 then
          open[finish] = vim.fn.foldclosed(finish) == -1
        end
      end
      turn_open[win] = open
    end)
  end
end

--- Flatten embedded newlines in a free-text field so a single audit field
--- can never inject a new buffer line (nvim_buf_set_lines rejects strings
--- containing '\n'). Multi-line tool output already arrives split via
--- `output`/`tool_result` events; this only guards the one-line annotations
--- built from model/tool-provided text (bash commands, retry errors, …).
local function flat(s)
  return (s or ""):gsub("[\r\n]+", " ")
end

--- Render one audit event as live-view lines. Returns (lines, kind)
--- where each line is { text = string, hl = highlight group|nil } and
--- kind is "section" (blank-line separated) or "stream" (appended verbatim —
--- streamed bash output chunks), or nil to render nothing.
local function render_event(ev)
  local ts = ev.ts or os.date("%Y-%m-%dT%H:%M:%S")
  if ev.type == "tool_start" then
    return { { text = "$ " .. flat(ev.command or ev.name or "tool"), hl = HL.command } }, "section"
  elseif ev.type == "output" then
    local out = {}
    for _, l in ipairs(vim.split(ev.data or "", "\n", { plain = true })) do
      out[#out + 1] = { text = l }
    end
    return out, "stream"
  elseif ev.type == "tool_call" then
    -- Record the requested command before the gate decides whether it runs;
    -- approval-paused bash/python calls never emit tool_start, so otherwise their
    -- approval request would have no preceding call in the audit view.
    local target = ""
    local ok, a = pcall(vim.json.decode, ev.args or "")
    if ok and type(a) == "table" then
      target = flat(a.path or a.url or a.command or "")
    end
    return { { text = ("• %s%s"):format(ev.name, target ~= "" and (" " .. target) or ""), hl = HL.tool } }, "section"
  elseif ev.type == "tool_result" then
    -- bash/python output already streamed via output events; don't duplicate it.
    if ev.name == "bash" or ev.name == "python" then
      return nil
    end
    local lines = {}
    if ev.result and ev.result ~= "" then
      for _, l in ipairs(vim.split(ev.result:gsub("\n$", ""), "\n", { plain = true })) do
        lines[#lines + 1] = { text = l }
      end
    end
    lines[#lines + 1] = { text = ("--- %s %s (%s bytes)"):format(ts, ev.name, ev.bytes or "?"), hl = HL.meta }
    return lines, "section"
  elseif ev.type == "alert_advisory" then
    local parts = { (flat(ev.reason)) }
    local p, sev, conf = tonumber(ev.p_alert), tonumber(ev.severity), tonumber(ev.confidence)
    if p then
      parts[#parts + 1] = ("P(harmful)=%.2f"):format(p)
    end
    if sev then
      local label = ("severity=%.2f"):format(sev)
      local cat = flat(ev.severity_category)
      if cat ~= "" then
        local prob = tonumber(ev.severity_category_prob)
        label = label .. (prob and (" %s (%.0f%%)"):format(cat, prob * 100) or (" " .. cat))
      end
      parts[#parts + 1] = label
    end
    if conf then
      parts[#parts + 1] = ("conf=%.2f"):format(conf)
    end
    local text = ("%s ⚠ %s: %s"):format(ts, flat(ev.name), table.concat(parts, " · "))
    local id = flat(ev.id)
    if id ~= "" then
      text = text .. (" [%s]"):format(id)
    end
    return { { text = text, hl = HL.warn } }, "section"
  elseif ev.type == "retry" then
    return {
      {
        text = ("%s retry #%d after %dms: %s"):format(ts, ev.attempt or 0, ev.delay_ms or 0, flat(ev.error)),
        hl = HL.warn,
      },
    },
      "section"
  elseif ev.type == "tool_text_warning" then
    local detail = flat(ev.detail)
    if detail == "" then
      detail = "model emitted a tool call as text"
    end
    return { { text = ("%s unexecuted tool call: %s"):format(ts, detail), hl = HL.warn } }, "section"
  elseif ev.type == "steer" then
    local text = flat(ev.text)
    return { { text = ("%s ⌁ steer: %s"):format(ts, text), hl = HL.warn } }, "section"
  elseif ev.type == "model_change" then
    if ev.error then
      return { { text = ("%s model switch to %s failed: %s"):format(ts, flat(ev.to), flat(ev.error)), hl = HL.warn } },
        "section"
    end
    return { { text = ("%s ⇄ model: %s → %s"):format(ts, flat(ev.from), flat(ev.to)), hl = HL.meta } }, "section"
  elseif ev.type == "approval_request" then
    local tool, reason = flat(ev.tool), flat(ev.reason)
    local context = tool
    if reason ~= "" then
      context = context ~= "" and (context .. ": " .. reason) or reason
    end
    local label = context ~= "" and (" (" .. context .. ")") or ""
    return {
      {
        text = ("%s %s approval requested [%s]%s: %s"):format(
          ts,
          require("harness").config.icons.approval,
          flat(ev.id),
          label,
          flat(ev.command)
        ),
        hl = HL.warn,
      },
    },
      "section"
  elseif ev.type == "approval_result" then
    return { { text = ("%s %s approval"):format(ts, ev.approved and "granted" or "denied"), hl = HL.warn } }, "section"
  elseif ev.type == "approval_timeout" then
    return { { text = ("%s approval timed out (denied)"):format(ts), hl = HL.warn } }, "section"
  elseif ev.type == "turn_end" then
    return {
      {
        text = ("# %s turn: %d in · %d out · %.1fs"):format(
          ts,
          ev.prompt or 0,
          ev.completion or 0,
          (ev.ms or 0) / 1000
        ),
        hl = HL.turn,
      },
    },
      "section"
  end
end

local function review_event(ev)
  return ev.type == "alert_advisory" or ev.type == "approval_request"
end

--- Rebuild the live view from a list of events: the full line list plus the
--- per-line highlights to reapply. Stream chunks append verbatim; section
--- events join with one blank line; the buffer keeps one trailing empty
--- line (the append invariant).
local function render_events(events)
  local lines, hl, has, reviews = {}, {}, false, {}
  for _, ev in ipairs(events) do
    local ev_lines, kind = render_event(ev)
    if ev_lines then
      if kind == "section" and has then
        lines[#lines + 1] = ""
      end
      local start = #lines
      if review_event(ev) then
        reviews[#reviews + 1] = start + 1 -- 1-based buffer line
      end
      for _, l in ipairs(ev_lines) do
        lines[#lines + 1] = l.text
      end
      for i, l in ipairs(ev_lines) do
        if l.hl then
          hl[#hl + 1] = { start + i - 1, l.hl }
        end
      end
      has = true
    end
  end
  lines[#lines + 1] = ""
  return lines, hl, reviews
end

--- Rebuild a live-view buffer from the full event list (the reopen path).
--- Returns whether the buffer now has content and the review event line map.
function M.rebuild(buf, events)
  local lines, hl, reviews = render_events(events)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hl) do
    vim.api.nvim_buf_add_highlight(buf, ns, h[2], h[1], 0, -1)
  end
  return #lines > 1 or lines[1] ~= "", reviews
end

--- Append one event to a live-view buffer. State `t` is { bufnr, has_content }.
--- Section events get a blank line before them (unless the view is empty);
--- stream events append directly. Per-line highlights are applied here.
function M.append(t, ev)
  local lines, kind = render_event(ev)
  if not lines then
    return
  end
  local buf = t.bufnr
  remember(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  local start = count - 1 -- 0-based index of the trailing empty line
  local lead = (kind == "section" and t.has_content) and 1 or 0
  local text = {}
  if lead == 1 then
    text[#text + 1] = ""
  end
  for _, l in ipairs(lines) do
    text[#text + 1] = l.text
  end
  text[#text + 1] = "" -- restore the trailing empty line
  vim.api.nvim_buf_set_lines(buf, start, start + 1, false, text)
  for i, l in ipairs(lines) do
    if l.hl then
      vim.api.nvim_buf_add_highlight(buf, ns, l.hl, start + lead + i - 1, 0, -1)
    end
  end
  if review_event(ev) then
    t.reviews[#t.reviews + 1] = start + lead + 1 -- 1-based buffer line
  end
  t.has_content = true
end

--- Follow only windows already near the bottom: scrolling up to read must
--- not be yanked back down by each streaming chunk.
local AUTOSCROLL_THRESHOLD = 10
function M.scroll(buf)
  local total = vim.api.nvim_buf_line_count(buf)
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(w) then
      local botline = vim.api.nvim_win_call(w, function()
        return vim.fn.line("w$")
      end)
      if total - botline <= AUTOSCROLL_THRESHOLD then
        vim.api.nvim_win_set_cursor(w, { total, 0 })
      end
    end
  end
end

--- Fold completed turns. The turn journal line is written on completion, so
--- it closes its turn: a turn folds from the line after the previous header
--- through its own header. The foldtext shows that header, so every completed
--- turn collapses to a summary line. The open turn after the last header stays
--- expanded so live output remains visible. Manual folds, applied from a
--- window showing the buffer; a hidden view folds the next time it is shown.
function M.fold(buf, force, open_new)
  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then
    return
  end
  local ends = headers(buf)
  for _, win in ipairs(wins) do
    vim.api.nvim_win_call(win, function()
      if vim.api.nvim_win_get_buf(win) ~= buf then
        return
      end
      -- Preserve existing manual choices. A turn that just completed was
      -- visible while it streamed, so leave its new fold open in a live view;
      -- replay/reopen still starts with completed turns collapsed.
      local open = {}
      if not force then
        for _, finish in ipairs(ends) do
          if open_new and turn_open[win] and turn_open[win][finish] ~= nil then
            open[finish] = turn_open[win][finish]
          elseif vim.fn.foldlevel(finish) > 0 and vim.fn.foldclosed(finish) == -1 then
            open[finish] = true
          end
        end
        if open_new then
          open[ends[#ends]] = true
        end
      end
      vim.wo.foldmethod = "manual"
      vim.wo.foldminlines = 0
      vim.wo.foldtext = "v:lua.require'harness.audit'.foldtext()"
      vim.cmd("normal! zE")
      local prev = 0
      for _, finish in ipairs(ends) do
        local start = prev + 1
        if finish >= start then
          vim.cmd(("%d,%dfold"):format(start, finish))
          vim.cmd(("%dfold%s"):format(start, open[finish] and "open" or "close"))
        end
        prev = finish
      end
      turn_open[win] = nil
    end)
  end
end

--- <leader>1: fold everything — collapse every completed turn, closing any
--- the user had left open. Same projection as M.fold but unconditional.
function M.fold_all(buf)
  M.fold(buf, true)
end

--- <leader>2: unfold everything — open every turn fold.
function M.unfold_all(buf)
  local wins = vim.fn.win_findbuf(buf)
  for _, win in ipairs(wins) do
    vim.api.nvim_win_call(win, function()
      if vim.api.nvim_win_get_buf(win) ~= buf then
        return
      end
      vim.wo.foldmethod = "manual"
      vim.wo.foldminlines = 0
      vim.wo.foldtext = "v:lua.require'harness.audit'.foldtext()"
      vim.cmd("normal! zR")
      turn_open[win] = nil
    end)
  end
end

--- Foldtext: a completed turn's header is its last line, so the closed fold
--- shows that summary line rather than the first tool/output line.
function M.foldtext()
  return vim.fn.getline(vim.v.foldend)
end

-- ─── Lifecycle ─────────────────────────────────────────────────────────────
-- Per-session-buffer persistent audit view: every audit event is rendered
-- into ONE unlisted buffer, yap://<session>-audit, opened by :YapLive. The
-- audit view is not a second log — it is the live, human-readable rendering
-- of the JSON Lines audit log, rebuilt from it on reopen. Only the audit log
-- is persisted.
local audits = {} -- session buf → { bufnr, offset, has_content, reviews, audit }
local audit_poll_timer

--- Cap the raw tool output streamed into the live audit view (and audit
--- log) per tool run. The returned tool result is already tail-truncated
--- to 50KB; the live audit view must not accumulate the full log — a
--- runaway command writing gigabytes would otherwise balloon the audit
--- view buffer (and audit log) and OOM the editor. 256KB is ample for
--- watching progress while keeping memory bounded.
local LIVE_OUTPUT_CAP = 256 * 1024

--- Append one event as a JSON object to the session's audit log.
local function write_log(buf, ev)
  local t = audits[buf]
  if not t then
    return
  end
  if not t.audit then
    t.audit = paths.audit_path(buf)
    -- 0700: the audit log holds full tool args and results (potentially
    -- secrets); the directory must not be world-readable.
    vim.fs.mkdir(vim.fn.fnamemodify(t.audit, ":h"), { parents = true, mode = 448 }) -- 0o700
  end
  vim.fn.writefile({ vim.json.encode(ev) }, t.audit, "a")
end

--- Point the audit log at the session file's name; a `:file` rename
--- (which also renames the session) renames the log to match.
function M.follow_rename(buf)
  local t = audits[buf]
  if not t or not t.audit or not vim.b[buf].yap_path then
    return
  end
  local want = paths.audit_path(buf)
  if want ~= t.audit and vim.fn.filereadable(want) == 0 then
    vim.fs.mkdir(vim.fn.fnamemodify(want, ":h"), { parents = true, mode = 448 }) -- 0o700
    if os.rename(t.audit, want) then
      t.audit = want
    end
  end
end

--- Seed the all-time session usage from the audit log: sum every turn_end
--- journal entry so a reopened session shows its full historical cost
--- immediately. yap_usage is per-buffer and resets on reopen; this is its
--- durable per-session counterpart (the audit log, not the session file,
--- is the source of truth).
function M.seed_session_usage(buf)
  local su = { prompt = 0, completion = 0 }
  local path = paths.audit_path(buf)
  if vim.fn.filereadable(path) == 1 then
    for _, line in ipairs(vim.fn.readfile(path)) do
      if line ~= "" then
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" and ev.type == "turn_end" then
          su.prompt = su.prompt + (ev.prompt or 0)
          su.completion = su.completion + (ev.completion or 0)
          if ev.cost then
            su.cost = (su.cost or 0) + ev.cost
          end
        end
      end
    end
  end
  vim.b[buf].yap_session_usage = su
end

--- The session buffer's audit-view state (and buffer), created on first use.
function M.ensure(buf)
  local t = audits[buf]
  if t and vim.api.nvim_buf_is_valid(t.bufnr) then
    return t
  end
  local name = paths.audit_buf_name(buf)
  local tbuf = util.find_or_create_buffer(name, false, true) -- unlisted scratch: never in :ls or buffer pickers
  vim.bo[tbuf].bufhidden = "hide"
  vim.bo[tbuf].modifiable = false

  t = { bufnr = tbuf, offset = 0, has_content = false }
  audits[buf] = t

  -- Replay the audit log so the live view survives restarts.
  local events = {}
  local path = paths.audit_path(buf)
  if vim.fn.filereadable(path) == 1 then
    for _, line in ipairs(vim.fn.readfile(path)) do
      if line ~= "" then
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" then
          events[#events + 1] = ev
        end
      end
    end
  end
  vim.bo[tbuf].modifiable = true
  t.has_content, t.reviews = M.rebuild(tbuf, events)
  vim.bo[tbuf].modifiable = false
  return t
end

--- Append an event to the audit log and render it into the audit view.
function M.append_event(buf, ev)
  local t = M.ensure(buf)
  write_log(buf, ev)
  vim.bo[t.bufnr].modifiable = true
  M.append(t, ev)
  vim.bo[t.bufnr].modifiable = false
  M.scroll(t.bufnr)
end

--- Append newly written bytes of the running tool's log to the audit
--- view buffer (called on the spinner tick, on tool_end, and on process
--- exit).
function M.drain(buf)
  local t, l = audits[buf], state.live[buf]
  if not t or not l then
    return
  end
  local fd = vim.uv.fs_open(l.log, "r", 438)
  if not fd then
    return
  end
  local stat = vim.uv.fs_fstat(fd)
  if not stat then
    vim.uv.fs_close(fd)
    return
  end
  local data
  local room = LIVE_OUTPUT_CAP - (l.out or 0)
  if stat.size > t.offset and room > 0 then
    local want = math.min(stat.size - t.offset, room)
    data = vim.uv.fs_read(fd, want, t.offset)
    if data then
      l.out = (l.out or 0) + #data
    end
  end
  t.offset = stat.size -- always advance past the read (or skipped) bytes
  vim.uv.fs_close(fd)
  if data and #data > 0 then
    M.append_event(buf, { type = "output", name = l.name, ts = os.date("%Y-%m-%dT%H:%M:%S"), data = data })
  elseif room <= 0 and stat.size > 0 and not l.truncated then
    l.truncated = true
    M.append_event(buf, {
      type = "output",
      name = l.name,
      ts = os.date("%Y-%m-%dT%H:%M:%S"),
      data = ("[live output truncated at %d bytes; remaining %d bytes not shown]\n"):format(
        LIVE_OUTPUT_CAP,
        stat.size - LIVE_OUTPUT_CAP
      ),
    })
  end
end

-- Poll tool logs independently of the visual spinner. Direct drains on
-- tool_end and process exit still capture the final bytes before cleanup.
function M.poll_stop_if_idle()
  if audit_poll_timer and not next(state.running) then
    audit_poll_timer:stop()
    audit_poll_timer:close()
    audit_poll_timer = nil
  end
end

function M.poll_start()
  if audit_poll_timer then
    return
  end
  audit_poll_timer = vim.uv.new_timer()
  audit_poll_timer:start(
    0,
    180,
    vim.schedule_wrap(function()
      for b in pairs(state.running) do
        M.drain(b)
      end
      M.poll_stop_if_idle()
    end)
  )
end

--- The session buffer's audit-view state, or nil (for callers that need the
--- view buffer or review line map).
function M.view(buf)
  return audits[buf]
end

--- Every session buffer's audit-view state, keyed by session buffer.
function M.views()
  return audits
end

return M
