-- The session's audit log, rendered live.
--
-- The live view (:YapLive) is a human-readable, highlighted, folded
-- projection of the JSON Lines audit log, rebuilt from it on reopen. This
-- module owns the rendering; the buffer lifecycle (create, replay on
-- reopen, the audit-log write) stays in harness.

local M = {}

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
    -- Record the requested command before the gate decides whether it runs;
    -- blocked bash/python calls never emit tool_start, so otherwise their
    -- approval request would have no preceding call in the audit view.
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
  elseif ev.type == "alert_advice" then
    return {
      {
        text = ("%s ⚠ alert [%s] %s: %s (P=%.2f, severity=%.2f)"):format(
          ts,
          flat(ev.id),
          flat(ev.name),
          flat(ev.reason),
          tonumber(ev.p_alert) or 0,
          tonumber(ev.severity) or 0
        ),
        hl = HL.warn,
      },
    },
      "block"
  elseif ev.type == "retry" then
    return {
      {
        text = ("%s retry #%d after %dms: %s"):format(ts, ev.attempt or 0, ev.delay_ms or 0, flat(ev.error)),
        hl = HL.warn,
      },
    },
      "block"
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
      "block"
  elseif ev.type == "approval_result" then
    return { { text = ("%s %s approval"):format(ts, ev.approved and "granted" or "denied"), hl = HL.warn } }, "block"
  elseif ev.type == "approval_timeout" then
    return { { text = ("%s approval timed out (denied)"):format(ts), hl = HL.warn } }, "block"
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
      "block"
  end
end

local function review_event(ev)
  return ev.type == "alert_advice" or ev.type == "approval_request"
end

--- Rebuild the live view from a list of events: the full line list plus the
--- per-line highlights to reapply. Stream chunks append verbatim; block
--- events join with one blank line; the buffer keeps one trailing empty
--- line (the append invariant).
local function render_events(events)
  local lines, hl, has, reviews = {}, {}, false, {}
  for _, ev in ipairs(events) do
    local ev_lines, kind = render_event(ev)
    if ev_lines then
      if kind == "block" and has then
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
function M.fold(buf, force)
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
      -- Remember which completed turns the user left open so a <Tab>-opened
      -- turn survives the re-fold below on the next turn_end. `force` (the
      -- <leader>1 fold-everything view key) ignores that and closes all.
      local open = {}
      if not force then
        for _, finish in ipairs(headers) do
          if vim.fn.foldlevel(finish) > 0 and vim.fn.foldclosed(finish) == -1 then
            open[finish] = true
          end
        end
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
          vim.cmd(("%dfold%s"):format(start, open[finish] and "open" or "close"))
        end
        prev = finish
      end
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
    end)
  end
end

--- Foldtext: a completed turn's header is its last line, so the closed fold
--- shows that summary line rather than the first tool/output line.
function M.foldtext()
  return vim.fn.getline(vim.v.foldend)
end

return M
