-- The session's audit log, and the live tool tail that follows it.
--
-- Two responsibilities, kept apart:
--
--   audit.jsonl is the append-only durable record (R-audit-log): every tool
--   call, result, attachment, approval request/answer, retry, steer,
--   model change and turn journal. `append_event` writes it; `:YapClear`
--   placeholders and the guard board read it. Nothing here renders it.
--
--   The live view (`:YapLive`) is a plain tail of the running tool's output:
--   one unlisted buffer per session that shows a `$ command` header per bash
--   call followed by that call's streamed bytes, newest at the bottom. It is
--   never replayed from the audit log — a stopped tool leaves an empty tail,
--   and the full output lives in the tool's temp log (and, for the result,
--   in the audit log's tool_result entry).

local M = {}

local paths = require("harness.path")
local util = require("harness.util")
local state = require("harness.state")
local view = require("harness.ui.view")

-- The `$ command` header is highlighted so it reads as a section marker
-- against streamed output; a horizontal rule separates consecutive commands.
-- Linked (not a fixed color) so every colorscheme renders it; `default`
-- keeps user overrides.
local ns = vim.api.nvim_create_namespace("yap.audit.hl")
local HL_CMD = "YapAuditCommand"
view.link(HL_CMD, "Title")

-- The tail keeps at most this many lines, always the newest: old lines are
-- dropped from the top, so a runaway command cannot balloon the buffer.
local MAX_TAIL_LINES = 5000

-- Per-session tail state: session buf -> { bufnr, rules }.
local tails = {}
local resize_autocmd = false
local resync -- defined after the rule helpers; used by the resize autocmd

--- The session's tail buffer, created on first use. Empty until a tool runs.
function M.ensure(buf)
  local t = tails[buf]
  if t and vim.api.nvim_buf_is_valid(t.bufnr) then
    return t
  end
  local name = paths.audit_buf_name(buf)
  local tbuf = util.find_or_create_buffer(name, false, true) -- unlisted scratch: never in :ls
  vim.bo[tbuf].bufhidden = "hide"
  vim.bo[tbuf].modifiable = false
  t = { bufnr = tbuf, rules = {} }
  tails[buf] = t
  if not resize_autocmd then
    resize_autocmd = true
    vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
      callback = function()
        for _, tt in pairs(tails) do
          resync(tt)
        end
      end,
    })
  end
  return t
end

-- Follow only windows already near the bottom: scrolling up to read must not
-- be yanked back down by each streaming chunk.
local AUTOSCROLL_THRESHOLD = 10
local function follow(buf)
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

--- Append lines to the tail, trimming old ones to keep only the newest.
--- Returns the 0-based row where `lines[1]` landed (after any trim), or nil
--- when nothing was appended.
local function append_lines(t, lines)
  if #lines == 0 then
    return nil
  end
  local buf = t.bufnr
  vim.bo[buf].modifiable = true
  local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start_row
  if #cur == 1 and cur[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, lines) -- replace the fresh empty line
    start_row = 0
  else
    start_row = #cur
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  end
  local count = vim.api.nvim_buf_line_count(buf)
  if count > MAX_TAIL_LINES then
    local drop = count - MAX_TAIL_LINES
    vim.api.nvim_buf_set_lines(buf, 0, drop, false, {})
    start_row = start_row - drop
    local shifted = {}
    for row in pairs(t.rules) do
      if row >= drop then
        shifted[row - drop] = true
      end
    end
    t.rules = shifted
  end
  vim.bo[buf].modifiable = false
  follow(buf)
  return start_row
end

--- The width a rule should span: the first window showing the tail, or a
--- generous fallback while the tail fills in the background (no window).
local function rule_width(buf)
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(w) then
      return vim.api.nvim_win_get_width(w)
    end
  end
  return 80
end

local function rule_line(width)
  return ("─"):rep(math.max(20, width))
end

--- Start a tool run in the tail: a `$ command` header (wrapped at shell
--- operators), preceded by a blank line and a rule separator once the tail
--- already holds an earlier command's output.
function M.tool_start(buf, command)
  local t = M.ensure(buf)
  local cmd = view.shell_lines(command or "", "  ")
  local has_prior = vim.api.nvim_buf_line_count(t.bufnr) > 1
    or vim.api.nvim_buf_get_lines(t.bufnr, 0, -1, false)[1] ~= ""
  local lines = {}
  if has_prior then
    lines[#lines + 1] = ""
    lines[#lines + 1] = rule_line(rule_width(t.bufnr))
  end
  lines[#lines + 1] = "$ " .. cmd[1]
  for i = 2, #cmd do
    lines[#lines + 1] = cmd[i]
  end
  local start_row = append_lines(t, lines)
  if has_prior then
    t.rules[start_row + 1] = true -- lines[2] is the rule separator
  end
  -- Highlight the trailing `$ command` header (possibly multi-line after
  -- shell-operator wrapping) so it stands apart from the output below.
  local head = vim.api.nvim_buf_line_count(t.bufnr) - #cmd
  for i = 0, #cmd - 1 do
    local text = vim.api.nvim_buf_get_lines(t.bufnr, head + i, head + i + 1, false)[1] or ""
    vim.api.nvim_buf_set_extmark(t.bufnr, ns, head + i, 0, {
      hl_group = HL_CMD,
      end_col = #text,
      right_gravity = false,
    })
  end
end

--- Re-render every rule separator to the tail's current window width, so a
--- rule drawn while the tail filled in the background (or before a resize)
--- always spans the view. Only separator lines (all ─) are touched.
resync = function(t)
  if not t or not t.rules or next(t.rules) == nil or not vim.api.nvim_buf_is_valid(t.bufnr) then
    return
  end
  local want = rule_line(rule_width(t.bufnr))
  vim.bo[t.bufnr].modifiable = true
  for row in pairs(t.rules) do
    local cur = vim.api.nvim_buf_get_lines(t.bufnr, row, row + 1, false)[1]
    if cur and cur ~= "" and cur:gsub("─", "") == "" and cur ~= want then
      vim.api.nvim_buf_set_lines(t.bufnr, row, row + 1, false, { want })
    end
  end
  vim.bo[t.bufnr].modifiable = false
end

function M.refresh(buf)
  resync(tails[buf])
end

--- Append a streamed chunk of one running tool's output to the tail. A line
--- not yet newline-terminated is buffered in the log state and only emitted
--- once it completes, so a partial write is never split across two fake
--- lines. This replaces the old temp-file polling: bytes arrive as ordered
--- `tool_output` frames on the same channel as tool_start/tool_end.
function M.tool_output(buf, log, delta)
  local t = tails[buf]
  local logs = state.live_logs[buf]
  if not t or not logs then
    return
  end
  local l = logs[log]
  if not l then
    return
  end
  local text = (l.pending or "") .. delta
  local lines = vim.split(text, "\n", { plain = true })
  l.pending = table.remove(lines)
  append_lines(t, lines)
end

--- Emit any unterminated tail line (e.g. a command's final write without a
--- trailing newline). `log` names one log to flush; nil flushes every log
--- (used on tool_end for one log, and on turn completion/cancel for all).
function M.flush(buf, log)
  local t = tails[buf]
  local logs = state.live_logs[buf]
  if not t or not logs then
    return
  end
  for _, l in pairs(logs) do
    if (not log or l.log == log) and l.pending and l.pending ~= "" then
      append_lines(t, { l.pending })
      l.pending = ""
    end
  end
end

--- Append one event as a JSON object to the session's audit log. The log is
--- the durable record; the tail view renders none of these events.
function M.append_event(buf, ev)
  local path = paths.audit_path(buf)
  paths.ensure_session_dir(vim.fn.fnamemodify(path, ":h"))
  -- Create the log 0600 before the first append so it is never briefly
  -- world-readable: writefile() would create it 0644 under a permissive umask.
  if vim.fn.filereadable(path) == 0 then
    local fd = vim.uv.fs_open(path, "wx", 384) -- 0600
    if fd then
      vim.uv.fs_close(fd)
    end
  end
  vim.fn.writefile({ vim.json.encode(ev) }, path, "a")
end

--- Fold one turn_end event's usage into a {prompt, completion, cost} table.
local function fold_usage(t, ev)
  t.prompt = (t.prompt or 0) + (ev.prompt or 0)
  t.completion = (t.completion or 0) + (ev.completion or 0)
  if ev.cost then
    t.cost = (t.cost or 0) + ev.cost
  end
  return t
end

--- The audit log is the single source of truth for usage totals. A turn_end
--- journal line is the terminal record of one turn's usage; both the
--- since-open total (yap_usage, resets on reopen) and the all-time session
--- total (yap_session_usage) are advanced from it here, so the two counters
--- can never drift apart.
function M.apply_turn_end(buf, ev)
  M.append_event(buf, ev)
  vim.b[buf].yap_usage = fold_usage(vim.b[buf].yap_usage or { prompt = 0, completion = 0 }, ev)
  vim.b[buf].yap_session_usage = fold_usage(vim.b[buf].yap_session_usage or { prompt = 0, completion = 0 }, ev)
end

--- Seed the all-time session usage from the audit log: sum every turn_end
--- journal entry so a reopened session shows its full historical cost
--- immediately. yap_usage is the since-open total and resets on reopen; the
--- audit log (not the session file) is the durable source of truth.
function M.seed_session_usage(buf)
  local su = { prompt = 0, completion = 0 }
  local path = paths.audit_path(buf)
  if vim.fn.filereadable(path) == 1 then
    for _, line in ipairs(vim.fn.readfile(path)) do
      if line ~= "" then
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" and ev.type == "turn_end" then
          fold_usage(su, ev)
        end
      end
    end
  end
  vim.b[buf].yap_session_usage = su
  vim.b[buf].yap_usage = nil
end

--- The session buffer's tail-view state, or nil.
function M.view(buf)
  return tails[buf]
end

--- Every session buffer's tail-view state, keyed by session buffer.
function M.views()
  return tails
end

return M
