-- The session's audit log, and the live tool tail that follows it.
--
-- Two responsibilities, kept apart:
--
--   audit.jsonl is the append-only durable record (R-audit-log): every tool
--   call, result, attachment, approval/advisory decision, retry, steer,
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
local view = require("harness.view")

-- The `$ command` header is highlighted so it reads as a section marker
-- against streamed output; a horizontal rule separates consecutive commands.
-- Linked (not a fixed color) so every colorscheme renders it; `default`
-- keeps user overrides.
local ns = vim.api.nvim_create_namespace("yap.audit.hl")
local HL_CMD = "YapAuditCommand"
vim.api.nvim_set_hl(0, HL_CMD, { link = "Title", default = true })

-- The tail keeps at most this many lines, always the newest: old lines are
-- dropped from the top, so a runaway command cannot balloon the buffer.
local MAX_TAIL_LINES = 5000

-- Per-session tail state: session buf -> { bufnr }.
local tails = {}
local audit_poll_timer

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
  t = { bufnr = tbuf }
  tails[buf] = t
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
local function append_lines(t, lines)
  if #lines == 0 then
    return
  end
  local buf = t.bufnr
  vim.bo[buf].modifiable = true
  local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #cur == 1 and cur[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, lines) -- replace the fresh empty line
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  end
  local count = vim.api.nvim_buf_line_count(buf)
  if count > MAX_TAIL_LINES then
    vim.api.nvim_buf_set_lines(buf, 0, count - MAX_TAIL_LINES, false, {})
  end
  vim.bo[buf].modifiable = false
  follow(buf)
end

--- A horizontal rule spanning the tail window, so one command's output ends
--- in a visible boundary before the next `$ command` header. The tail is
--- often filled in the background while no window shows it, so the width is
--- unknowable there and falls back to a generous fixed rule.
local function rule(buf)
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(w) then
      return ("─"):rep(math.max(20, vim.api.nvim_win_get_width(w)))
    end
  end
  return ("─"):rep(80)
end

--- Start a tool run in the tail: a `$ command` header (wrapped at shell
--- operators), preceded by a blank line and a rule separator once the tail
--- already holds an earlier command's output.
function M.tool_start(buf, command)
  local t = M.ensure(buf)
  local cmd = view.shell_lines(command or "", "  ")
  local lines = {}
  if vim.api.nvim_buf_line_count(t.bufnr) > 1 or vim.api.nvim_buf_get_lines(t.bufnr, 0, -1, false)[1] ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = rule(t.bufnr)
  end
  lines[#lines + 1] = "$ " .. cmd[1]
  for i = 2, #cmd do
    lines[#lines + 1] = cmd[i]
  end
  append_lines(t, lines)
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

--- Follow new bytes of each running tool's temp log into the tail. A line not
--- yet newline-terminated is buffered in the log state and only emitted once
--- it completes, so a partial write is never split across two fake lines.
function M.drain(buf)
  local t = tails[buf]
  local logs = state.live_logs[buf]
  if not t or not logs then
    return
  end
  for _, l in pairs(logs) do
    local fd = vim.uv.fs_open(l.log, "r", 438)
    if fd then
      local stat = vim.uv.fs_fstat(fd)
      if stat and stat.size > (l.offset or 0) then
        local data = vim.uv.fs_read(fd, stat.size - (l.offset or 0), l.offset or 0)
        l.offset = stat.size
        if data and #data > 0 then
          local text = (l.pending or "") .. data
          local lines = vim.split(text, "\n", { plain = true })
          l.pending = table.remove(lines)
          append_lines(t, lines)
        end
      end
      vim.uv.fs_close(fd)
    end
  end
end

--- Emit any unterminated tail line (e.g. a command's final write without a
--- trailing newline). `log` names one log to flush; nil flushes every log
--- (used on process exit / stop, when all logs are torn down).
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
  vim.fn.setfperm(path, "rw-------") -- also tighten a legacy 0644 log
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

--- The session buffer's tail-view state, or nil.
function M.view(buf)
  return tails[buf]
end

--- Every session buffer's tail-view state, keyed by session buffer.
function M.views()
  return tails
end

return M
