-- The session's audit log, rendered two ways.
--
-- The live view (:YapLive) is a human-readable, highlighted, folded
-- projection of the JSON Lines audit log, rebuilt from it on reopen. The
-- raw browser (:YapAudit) is a split-panel viewer for the raw file itself:
-- one event per line on the left, a readable record on the right. This
-- module owns both renderings; the buffer lifecycle (create, replay on
-- reopen, the audit-log write) stays in harness.

local M = {}

local paths = require("harness.path")

-- ─── Highlight groups ──────────────────────────────────────────────────────

-- Structural lines are colored, content stays default so streamed/returned
-- text reads as plain text. Links (not fixed colors) so every colorscheme
-- renders them; `default` keeps user overrides.
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

-- The raw JSONL list is colored by event type (one event per line).
local TYPE_HL = {
  tool_call = "YapAuditRawTool",
  tool_result = "YapAuditRawResult",
  tool_start = "YapAuditRawTool",
  output = "YapAuditRawOutput",
  turn_end = "YapAuditRawTurn",
  retry = "YapAuditRawWarn",
  tool_text_warning = "YapAuditRawWarn",
  steer = "YapAuditRawWarn",
  approval_request = "YapAuditRawWarn",
  approval_result = "YapAuditRawWarn",
  approval_timeout = "YapAuditRawWarn",
}
link("YapAuditRawTool", "Function")
link("YapAuditRawResult", "String")
link("YapAuditRawOutput", "Comment")
link("YapAuditRawTurn", "Title")
link("YapAuditRawWarn", "WarningMsg")

-- Namespace for the live view's per-line highlights.
local live_ns = vim.api.nvim_create_namespace("yap.audit.hl")
-- Namespace for the raw browser's per-line highlights.
local raw_ns = vim.api.nvim_create_namespace("yap.audit.raw")

-- A turn journal line (the live view's section header): `# <ts> turn <model>: …`.
local TURN = "^# %d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d turn "

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
--- kind is "block" (blank-line separated) or "stream" (appended verbatim —
--- streamed bash output chunks), or nil to render nothing.
local function render_event(ev)
  local ts = ev.ts or os.date("%Y-%m-%dT%H:%M:%S")
  if ev.type == "tool_start" then
    return { { text = "$ " .. flat(ev.command or ev.name or "tool"), hl = HL.command } }, "block"
  elseif ev.type == "output" then
    local out = {}
    for _, l in ipairs(vim.split(ev.data or "", "\n", { plain = true })) do
      out[#out + 1] = { text = l }
    end
    return out, "stream"
  elseif ev.type == "tool_call" then
    -- bash/python render their own `$ command` header from tool_start; the
    -- full arguments are still in the audit log as this event.
    if ev.name == "bash" or ev.name == "python" then
      return nil
    end
    local target = ""
    local ok, a = pcall(vim.json.decode, ev.args or "")
    if ok and type(a) == "table" then
      target = flat(a.path or a.url or a.command or "")
    end
    return { { text = ("• %s%s"):format(ev.name, target ~= "" and (" " .. target) or ""), hl = HL.tool } }, "block"
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
    return lines, "block"
  elseif ev.type == "retry" then
    return { { text = ("%s retry #%d after %dms: %s"):format(ts, ev.attempt or 0, ev.delay_ms or 0, flat(ev.error)), hl = HL.warn } }, "block"
  elseif ev.type == "tool_text_warning" then
    local detail = flat(ev.detail)
    if detail == "" then
      detail = "model emitted a tool call as text"
    end
    return { { text = ("%s unexecuted tool call: %s"):format(ts, detail), hl = HL.warn } }, "block"
  elseif ev.type == "steer" then
    local text = flat(ev.text)
    return { { text = ("%s ⌁ steer: %s"):format(ts, text), hl = HL.warn } }, "block"
  elseif ev.type == "approval_request" then
    local tool, reason = flat(ev.tool), flat(ev.reason)
    local context = tool
    if reason ~= "" then
      context = context ~= "" and (context .. ": " .. reason) or reason
    end
    local label = context ~= "" and (" (" .. context .. ")") or ""
    return { { text = ("%s %s approval requested%s: %s"):format(ts, require("harness").config.icons.approval, label, flat(ev.command)), hl = HL.warn } }, "block"
  elseif ev.type == "approval_result" then
    return { { text = ("%s %s approval"):format(ts, ev.approved and "granted" or "denied"), hl = HL.warn } }, "block"
  elseif ev.type == "approval_timeout" then
    return { { text = ("%s approval timed out (denied)"):format(ts), hl = HL.warn } }, "block"
  elseif ev.type == "turn_end" then
    local cost = ev.cost and (" · " .. string.format("$%.4g", ev.cost)) or ""
    local model = flat(ev.model)
    if model == "" then
      model = "?"
    end
    return { { text = ("# %s turn %s: %d in · %d out%s · %.1fs"):format(
      ts,
      model,
      ev.prompt or 0,
      ev.completion or 0,
      cost,
      (ev.ms or 0) / 1000
    ), hl = HL.turn } }, "block"
  end
end

--- Rebuild the live view from a list of events: the full line list plus the
--- per-line highlights to reapply. Stream chunks append verbatim; block
--- events join with one blank line; the buffer keeps one trailing empty
--- line (the append invariant).
local function render_events(events)
  local lines, hl, has = {}, {}, false
  for _, ev in ipairs(events) do
    local ev_lines, kind = render_event(ev)
    if ev_lines then
      if kind == "block" and has then
        lines[#lines + 1] = ""
      end
      local start = #lines
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
  return lines, hl
end

--- Rebuild a live-view buffer from the full event list (the reopen path).
--- Returns whether the buffer now has content.
function M.rebuild(buf, events)
  local lines, hl = render_events(events)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, live_ns, 0, -1)
  for _, h in ipairs(hl) do
    vim.api.nvim_buf_add_highlight(buf, live_ns, h[2], h[1], 0, -1)
  end
  return #lines > 1 or lines[1] ~= ""
end

--- Append one event to a live-view buffer. State `t` is { bufnr, has_content }.
--- Block events get a blank line before them (unless the view is empty);
--- stream events append directly. Per-line highlights are applied here.
function M.append(t, ev)
  local lines, kind = render_event(ev)
  if not lines then
    return
  end
  local buf = t.bufnr
  local count = vim.api.nvim_buf_line_count(buf)
  local start = count - 1 -- 0-based index of the trailing empty line
  local lead = (kind == "block" and t.has_content) and 1 or 0
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
      vim.api.nvim_buf_add_highlight(buf, live_ns, l.hl, start + lead + i - 1, 0, -1)
    end
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
function M.fold(buf)
  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local headers = {}
  for i, line in ipairs(lines) do
    if line:match(TURN) then
      headers[#headers + 1] = i
    end
  end
  for _, win in ipairs(wins) do
    vim.api.nvim_win_call(win, function()
      if vim.api.nvim_win_get_buf(win) ~= buf then
        return
      end
      vim.wo.foldmethod = "manual"
      vim.wo.foldminlines = 0
      vim.wo.foldtext = "v:lua.require'harness.audit'.foldtext()"
      vim.cmd("normal! zE")
      local prev = 0
      for _, finish in ipairs(headers) do
        local start = prev + 1
        if finish >= start then
          vim.cmd(("%d,%dfold"):format(start, finish))
          vim.cmd(("%dfoldclose"):format(start))
        end
        prev = finish
      end
    end)
  end
end

--- Foldtext: a completed turn's header is its last line, so the closed fold
--- shows that summary line rather than the first tool/output line.
function M.foldtext()
  return vim.fn.getline(vim.v.foldend)
end

-- ─── Raw JSONL browser (:YapAudit) ─────────────────────────────────────────

--- Render one decoded event as readable lines: fields sorted, and multiline
--- string fields (results, output chunks) emitted as raw text so they read
--- as prose instead of escaped JSON.
local function render_record(ev)
  if type(ev) ~= "table" or next(ev) == nil then
    return { vim.json.encode(ev) }
  end
  local keys = vim.tbl_keys(ev)
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    local v = ev[k]
    if type(v) == "string" and v:find("\n", 1, true) then
      out[#out + 1] = vim.json.encode(k) .. ":"
      for _, l in ipairs(vim.split(v, "\n", { plain = true })) do
        out[#out + 1] = "  " .. l
      end
    else
      out[#out + 1] = string.format("%s: %s", vim.json.encode(k), vim.json.encode(v))
    end
  end
  return out
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function highlight_source(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, raw_ns, 0, -1)
  for i, line in ipairs(lines) do
    if line ~= "" then
      local ok, ev = pcall(vim.json.decode, line)
      if ok and type(ev) == "table" then
        local hl = TYPE_HL[ev.type]
        if hl then
          vim.api.nvim_buf_add_highlight(buf, raw_ns, hl, i - 1, 0, -1)
        end
      end
    end
  end
end

local browser = {}

local function update_preview()
  local source, preview = browser.source_buf, browser.preview_buf
  if not (source and preview and vim.api.nvim_buf_is_valid(source) and vim.api.nvim_buf_is_valid(preview)) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(browser.source_win)[1]
  local line = vim.api.nvim_buf_get_lines(source, cursor - 1, cursor, false)[1]
  local out
  if not line or line == "" then
    out = { "" }
  else
    local ok, ev = pcall(vim.json.decode, line)
    if ok and type(ev) == "table" then
      out = render_record(ev)
    else
      out = { "(invalid JSON) " .. tostring(ev) }
    end
  end
  set_lines(preview, out)
end

local function close()
  for _, win in ipairs({ browser.preview_win, browser.source_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  browser.source_buf, browser.preview_buf = nil, nil
  browser.source_win, browser.preview_win = nil, nil
end

--- Open the split-panel viewer for a JSONL path.
function M.open(path)
  close() -- one viewer at a time

  local lines = vim.fn.readfile(path)

  local source = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(source, "yap://audit:" .. path)
  vim.bo[source].buftype = "nofile"
  vim.bo[source].bufhidden = "wipe"
  vim.bo[source].swapfile = false
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  vim.bo[source].modifiable = false
  highlight_source(source, lines)

  local preview = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(preview, "yap://audit-preview")
  vim.bo[preview].buftype = "nofile"
  vim.bo[preview].bufhidden = "wipe"
  vim.bo[preview].swapfile = false
  vim.bo[preview].modifiable = false

  -- Source to the right of the current window, preview to the right of it,
  -- so the chat (or whatever buffer) is left untouched.
  vim.cmd("rightbelow vsplit")
  local source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(source_win, source)
  vim.wo[source_win].wrap = false
  vim.wo[source_win].cursorline = true

  vim.cmd("rightbelow vsplit")
  local preview_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(preview_win, preview)
  vim.wo[preview_win].foldmethod = "indent"
  vim.wo[preview_win].foldlevel = 99

  browser.source_buf = source
  browser.preview_buf = preview
  browser.source_win = source_win
  browser.preview_win = preview_win

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = source,
    callback = update_preview,
  })

  for _, b in ipairs({ source, preview }) do
    vim.keymap.set("n", "q", close, { buffer = b, silent = true, desc = "Close audit viewer" })
  end

  vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
  update_preview()
end

--- :YapAudit — open the current session's audit log. Works only in a yap
--- buffer (the audit log is keyed off the session's basename and cwd).
function M.view()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.b[buf].yap then
    vim.notify("yap: :YapAudit only works in a yap session", vim.log.levels.WARN)
    return
  end
  local path = paths.audit_path(buf)
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("yap: no audit log yet for this session", vim.log.levels.WARN)
    return
  end
  M.open(path)
end

return M
