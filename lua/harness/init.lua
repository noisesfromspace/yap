-- yap.nvim — the buffer is the conversation.
--
-- A yap buffer is plain markdown. Headings of the form `# @user`,
-- `# @assistant` and `# @system` delimit messages; everything between
-- headings is message content. The buffer is the ONLY state: deleting a
-- block removes it from the conversation, editing an assistant reply
-- changes what the model "said", inserting a fake reply steers it.
-- gptel semantics, Neovim native.
--
-- Sending serializes the whole buffer to the `yap` binary, which talks
-- to the provider and streams the reply back into the buffer.

local M = {}

local paths = require("harness.path")

M.config = {
  bin = "yap", -- path to the yap binary
  provider = "moonshot",
  model = "kimi-k3",
  -- Optional override list of "provider/model" combos for
  -- :YapChangeModel. When unset, the picker queries every provider
  -- in config.json for its model list (GET /models).
  models = nil,
  -- System prompt for new buffers: read from agents_file if it exists
  -- (pi-style ~/.config/yap/AGENTS.md), otherwise this fallback.
  system = "You are a helpful coding assistant. Answer concisely.",
  agents_file = (vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. "/.config")) .. "/yap/AGENTS.md",
  -- Templates are text files inserted into the context by :YapInsert
  -- (a compaction prompt, a snippet, ...); skills are the same but
  -- system-prompt material, merged into the # @system block.
  templates_dir = (vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. "/.config")) .. "/yap/templates",
  skills_dir = (vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. "/.config")) .. "/yap/skills",
  roles_dir = "~/.yap/roles", -- subagent role definitions
  -- Session and audit data roots. Defaults mirror harness.path (resolved
  -- against the real home directory, never the project cwd); override in
  -- setup() to relocate them.
  sessions_dir = paths.dirs.sessions_dir,
  audit_dir = paths.dirs.audit_dir,
  -- List available skills (name + description) in new chats' system block
  -- so they are discoverable; bodies are only ever inserted manually.
  skills_intro = true,
  -- vim.notify when a turn completes in a buffer that is not focused
  -- (see the User YapTurnDone autocmd installed by setup()).
  notify_done = true,
  -- Keep treesitter's markdown syntax highlighting on yap buffers. It is
  -- on by default: the highlighter is incremental and measured to be
  -- negligible (~0.001ms/scroll) — the per-redraw cost attributed to
  -- "treesitter" in profiling was actually touchup re-rendering plus live
  -- buffer churn, not the highlighter. Set false to drop syntax colors.
  syntax_highlight = true,
  -- Terminal glyph availability cannot be detected reliably; set false to use
  -- plain Unicode status glyphs, the original spinner and block gauge.
  nerd_font = true,
  -- UI glyphs for the winbar and session picker (see doc/yap.txt
  -- |yap-winbar|). Defaults are Nerd Font v3 glyphs; the plain-unicode
  -- fallback preset for unpatched fonts is under |yap-configuration|.
  -- Set any to "" to drop its glyph.
  icons = {
    since = "󰅐",   -- nf-md-clock_outline (since-open token/cost chip)
    total = "󰆼",   -- nf-md-database   (all-time token/cost chip)
    running = "", -- nf-cod-play (rollup: other sessions streaming)
    error = "󰚌",   -- nf-md-skull (winbar error state)
    waiting = "󱀒", -- waiting (rollup: other sessions awaiting you)
    idle = "󰝦",    -- nf-md-circle_outline (picker idle state)
    steer = "󰇐",   -- nf-md-directions (winbar steer state)
    approval = "󰻌", -- nf-md-shield_alert (approval requested in audit)
    fold = "",    -- nf-oct-fold      (fold-view chip)
    cap_l = "",   -- nf-ple-lower_right_triangle (island left cap)
    cap_r = "",   -- nf-ple-lower_left_triangle  (island right cap)
  },
  -- Smallest model that labels the session from the latest user message
  -- as soon as it is sent, so the winbar and session picker have a title
  -- before the agent answers.
  description_model = "openai/gpt-5-nano",
  -- Bigger model that writes the final title once the turn completes
  -- (back on the # @user block): a whole-session summary that tells the
  -- story so the session is easy to find in the picker later.
  description_answer_model = "openai/gpt-5-mini",
  -- Every keymap is a config key (see doc/yap.txt §3); set one to ""
  -- to disable it. Buffer-local maps are applied when a session opens;
  -- `sessions` and `waiting` are global (installed by setup()).
  keymaps = {
    send = "<C-s>",
    stop = "<C-c>",
    change_model = "<leader>m",
    live = "<leader>l",
    scratch = "<leader>s",
    insert = "<C-t>",
    insert_here = "<leader>T",
    sessions = "<leader>r",
    waiting = "<leader>w",
    help = "g?",

    next_message = "]m",
    prev_message = "[m",
    next_user = "]u",
    prev_user = "[u",
    next_assistant = "]a",
    prev_assistant = "[a",
    next_tool = "]t",
    prev_tool = "[t",
    next_think = "]c",
    prev_think = "[c",
    next_error = "]e",
    prev_error = "[e",

    view_1 = "<leader>1",
    view_2 = "<leader>2",
    view_3 = "<leader>3",
    toggle_fold = "<Tab>",

    inner_message = "im",
    around_message = "am",
    inner_block = "it",
    around_block = "at",
  },
}

-- Keep the last successful discovery on disk. A refresh starts in the
-- background during setup; the picker uses the cached list immediately.
local models_cache = nil
local models_waiters = {}
local models_refreshing = false

local function models_cache_path()
  return vim.fn.stdpath("cache") .. "/yap/models"
end

local function refresh_models()
  if models_refreshing then return end
  models_refreshing = true
  vim.system({ M.config.bin, "models" }, { text = true }, function(res)
    vim.schedule(function()
      models_refreshing = false
      local combos = {}
      if res.code == 0 then
        for line in (res.stdout or ""):gmatch("[^\n]+") do
          table.insert(combos, line)
        end
      end
      if #combos > 0 then
        models_cache = combos
        local path = models_cache_path()
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile(combos, path)
      end
      for _, waiter in ipairs(models_waiters) do
        waiter(models_cache, res.stderr)
      end
      models_waiters = {}
    end)
  end)
end

local state = require("harness.state")
local util = require("harness.util")
local frontmatter = require("harness.frontmatter")
local winbar = require("harness.winbar")

M.winbar = winbar.winbar
M.overview = winbar.overview

-- Shared per-buffer state lives in harness.state; these aliases keep the
-- orchestration code reading like the pre-split module. The winbar reads
-- the same tables directly.
local running = state.running
local live = state.live
local errors = state.errors
local last_turn = state.last_turn
local awaiting = state.awaiting
local steer = state.steer

local start_subagent
local subagent_done = {}
local subagent_children = {}
-- close_session is a request-scoped frontend side effect (like quickfix):
-- the agent asked to end the session, so the buffer is wiped once the turn
-- has fully completed and the session file has been saved.
local close_after_turn = {}

-- Honor a close_session request by wiping the buffer. The turn has already
-- been saved by whichever completion path reached this point.
local function close_if_requested(buf)
  if close_after_turn[buf] then
    close_after_turn[buf] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

-- Most-recently-focused buffers, front first. Session buffers are unlisted,
-- so Neovim's :bd/:bw/:close skip them when choosing where to land after
-- deleting the current buffer and drop the user on an empty "No Name"
-- buffer instead (the "deleting the last listed buffer" path). This order
-- redirects that landing back to the buffer the user came from.
local focus_mru = {}

local function focus_touch(buf)
  for i, b in ipairs(focus_mru) do
    if b == buf then
      table.remove(focus_mru, i)
      break
    end
  end
  table.insert(focus_mru, 1, buf)
end

local function focus_forget(buf)
  for i, b in ipairs(focus_mru) do
    if b == buf then
      table.remove(focus_mru, i)
      return
    end
  end
end

-- Landing spot after closing the current session: the most recently focused
-- session awaiting a reply, otherwise a running session, otherwise the last
-- non-session (file) buffer. Idle sessions are not a landing spot.
local function focus_fallback(buf)
  local function open(b)
    return b ~= buf and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b)
  end
  for _, b in ipairs(focus_mru) do
    if open(b) and vim.b[b].yap and awaiting[b] then
      return b
    end
  end
  for _, b in ipairs(focus_mru) do
    if open(b) and vim.b[b].yap and running[b] then
      return b
    end
  end
  for _, b in ipairs(focus_mru) do
    if open(b) and not vim.b[b].yap then
      return b
    end
  end
  return nil
end

-- The harness's own boilerplate, always injected as the first system
-- message on every send. It is independent of agents_file (the user's
-- rules) and lives here so session files never store it.
local function yap_about()
  return [[# About Yap

You are running inside Yap, an agent harness for Neovim. The conversation is an editable Markdown buffer and the source of truth: `# @system`, `# @user`, and `# @assistant` headings delimit messages; editing or deleting a message branches or rewrites history, and the visible transcript is what is re-sent. Never emit one of those headings or a `<!-- yap:` marker line in a reply — indent or fence it instead.

Between turns, tool calls and their results are plain text in the transcript, not re-executed or re-sent. When asked about Yap itself, read `README.md` / `doc/yap.txt` in the project (normally `/opt/code/yap`) rather than guessing.

For GitHub searches and reading GitHub code, repositories, issues, pull requests, files, or Projects, use the `github` tool rather than curl, fetch, websearch, bash, or `gh`. Use other tools only if the `github` tool cannot perform the needed operation; never pass the GitHub token in tool arguments.

## Skills

Skills are reusable on-demand instructions in Markdown files under ]] .. M.config.skills_dir .. [[ (`<name>.md`). The `## Skills` list in the system block names them. Before working in a listed domain, `read` the matching skill file and follow it; read only what you need.

## Subagents

- `subagent` takes a `role` (from `roles_dir`, default `~/.yap/roles/<role>.md`) and a self-contained `task`. It blocks until the child finishes and returns the child's answer and session path; inspect the child session for its full conversation. A bare model name inherits the parent's provider/model.
]]
end

local function system_prompt()
  local f = io.open(M.config.agents_file, "r")
  if f then
    local text = f:read("*a")
    f:close()
    text = text:gsub("%s+$", "")
    if text ~= "" then
      return text
    end
  end
  return M.config.system
end

local HEAD = "^# @(%a+)%s*$"
local document = require("harness.document")
local fold = require("harness.fold")

--- End line (0-based, exclusive) of the frontmatter block, or nil when
--- the buffer has none. Only the model state lives there (see
--- harness.frontmatter); token/cost totals stay in the winbar.
local function frontmatter_end(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 200, false)
  if not lines[1] or not lines[1]:match("^%-%-%-%s*$") then
    return nil
  end
  for i = 2, #lines do
    if lines[i]:match("^%-%-%-%s*$") then
      return i
    end
  end
  return nil
end

--- Rewrite the buffer's frontmatter to match the current combo, growing
--- the `models` history. Called only from new()/change_model() — never
--- during a send (R7: sends only append).
local function sync_frontmatter(buf)
  local provider, model = util.current_combo(buf)
  local combo = provider .. "/" .. model
  local e = frontmatter_end(buf)
  local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false)) or nil
  local models = fm and fm.models or {}
  if #models == 0 and fm and fm.provider and fm.model then
    table.insert(models, fm.provider .. "/" .. fm.model)
  end
  if models[#models] ~= combo then
    table.insert(models, combo)
  end
  local created_at = (fm and fm.created_at) or os.date("!%Y-%m-%dT%H:%M:%SZ")
  local block = frontmatter.render(provider, model, models, created_at, fm and fm.description, fm and fm.role or vim.b[buf].yap_role, fm and fm.tools or vim.b[buf].yap_tools, fm and fm.subagents, fm and fm.updated_at, fm and fm.turns)
  if e then
    vim.api.nvim_buf_set_lines(buf, 0, e, false, block)
  else
    table.insert(block, "")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, block)
  end
end

--- Append a subagent session path to the parent's frontmatter `subagents`
--- list. The parent frontmatter is the index of every subagent it ran, and
--- the only way back to a closed child (subagent sessions are hidden from
--- :YapSessions — see harness.session).
local function record_subagent(parent, child_path)
  local e = frontmatter_end(parent)
  if not e then return end
  local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(parent, 0, e, false))
  if not fm then return end
  local subagents = fm.subagents or {}
  for _, p in ipairs(subagents) do
    if p == child_path then return end
  end
  subagents[#subagents + 1] = child_path
  local block = frontmatter.render(fm.provider, fm.model, fm.models, fm.created_at, fm.description, fm.role, fm.tools, subagents, fm.updated_at, fm.turns)
  vim.api.nvim_buf_set_lines(parent, 0, e, false, block)
end

-- Conversation document parsing/appending lives in harness.document.

-- Templates and skills live in harness.template.

--- Find the yap:usage marker the binary appended for this turn, fold its
--- numbers into the buffer's session totals (winbar), and remove the marker.
local function consume_usage(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = #lines, 1, -1 do
    local json = lines[i]:match("^<!%-%- yap:usage (.+) %-%->$")
    if json then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, {})
      local ok, data = pcall(vim.json.decode, json)
      if ok and type(data) == "table" then
        local u = vim.b[buf].yap_usage or { prompt = 0, completion = 0 }
        u.prompt = u.prompt + (data.prompt or 0)
        u.completion = u.completion + (data.completion or 0)
        if data.cost then
          u.cost = (u.cost or 0) + data.cost
        end
        vim.b[buf].yap_usage = u
      end
      return
    end
  end
end

function M.parse_buffer(buf)
  return document.parse_buffer(buf)
end
function M.insert(name, opts)
  return require("harness.template").insert(name, opts)
end
function M.template_names()
  return require("harness.template").template_names()
end
function M.is_running(buf)
  return state.is_running(buf)
end

-- ─── Send ──────────────────────────────────────────────────────────────────

-- One persistent serve backend per chat buffer, so several sessions can
-- stream at once. Each backend keeps its own tool state (SSH connections
-- above all) for the life of its buffer; a stopped process is restarted
-- on the next send.
local servers = {} -- buf → vim.SystemObj

-- buf → flush function: flushes streamed stdout that has been buffered for
-- a redraw tick into the buffer. The send path coalesces per-token stdout
-- flushes into one edit per ~STREAM_FLUSH_MS so a fast model streaming
-- many tokens a second does not force Neovim to recompute expr folds once
-- per token (O(n) per edit on large sessions).
local stream_flush = {}

-- Per-chat-buffer persistent tail: every audit event is rendered into
-- ONE unlisted buffer, yap://<session>-tail, opened by :YapLive. The
-- tail is not a second log — it is the live, human-readable rendering
-- of the JSON Lines audit log (see audit_path), rebuilt from it on
-- reopen. Only the audit log is persisted.
local tails = {} -- chat buf → { bufnr, offset, has_content, audit }

-- The audit dir holds one JSON Lines audit log per session, keyed by
-- the session's basename, so the sessions dir stays clean.

--- Append one event as a JSON object to the session's audit log.
local function audit_append(buf, ev)
  local t = tails[buf]
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
local function audit_follow(buf)
  local t = tails[buf]
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
local function seed_session_usage(buf)
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

--- Render one audit event as tail-buffer text. Returns (text, kind)
--- where kind is "block" (blank-line separated) or "stream" (appended
--- verbatim — streamed bash output chunks), or nil to render nothing.
local function render_event(ev)
  local ts = ev.ts or os.date("%Y-%m-%dT%H:%M:%S")
  if ev.type == "tool_start" then
    return "$ " .. (ev.command or ev.name or "tool"), "block"
  elseif ev.type == "output" then
    return ev.data or "", "stream"
  elseif ev.type == "tool_call" then
    -- bash/python render their own `$ command` header from tool_start; the
    -- full arguments are still in the audit log as this event.
    if ev.name == "bash" or ev.name == "python" then
      return nil
    end
    local target = ""
    local ok, a = pcall(vim.json.decode, ev.args or "")
    if ok and type(a) == "table" then
      target = a.path or a.url or a.command or ""
    end
    return ("• %s%s"):format(ev.name, target ~= "" and (" " .. target) or ""), "block"
  elseif ev.type == "tool_result" then
    -- bash/python output already streamed via output events; don't duplicate it.
    if ev.name == "bash" or ev.name == "python" then
      return nil
    end
    local lines = {}
    if ev.result and ev.result ~= "" then
      vim.list_extend(lines, vim.split(ev.result:gsub("\n$", ""), "\n", { plain = true }))
    end
    table.insert(lines, ("--- %s %s (%s bytes)"):format(ts, ev.name, ev.bytes or "?"))
    return table.concat(lines, "\n"), "block"
  elseif ev.type == "retry" then
    return ("%s retry #%d after %dms: %s"):format(ts, ev.attempt or 0, ev.delay_ms or 0, ev.error or ""), "block"
  elseif ev.type == "tool_text_warning" then
    return ("%s unexecuted tool call: %s"):format(ts, ev.detail or "model emitted a tool call as text"), "block"
  elseif ev.type == "steer" then
    local text = (ev.text or ""):gsub("\n", " ")
    return ("%s ⌁ steer: %s"):format(ts, text), "block"
  elseif ev.type == "approval_request" then
    local context = ev.tool or ""
    if ev.reason and ev.reason ~= "" then
      context = context ~= "" and (context .. ": " .. ev.reason) or ev.reason
    end
    local label = context ~= "" and (" (" .. context .. ")") or ""
    return ("%s %s approval requested%s: %s"):format(ts, M.config.icons.approval, label, (ev.command or ""):gsub("\n", " ")), "block"
  elseif ev.type == "approval_result" then
    return ("%s %s approval"):format(ts, ev.approved and "granted" or "denied"), "block"
  elseif ev.type == "approval_timeout" then
    return ("%s approval timed out (denied)"):format(ts), "block"
  elseif ev.type == "turn_end" then
    local cost = ev.cost and (" · " .. string.format("$%.4g", ev.cost)) or ""
    return ("# %s turn %s: %d in · %d out%s · %.1fs"):format(
      ts,
      ev.model or "?",
      ev.prompt or 0,
      ev.completion or 0,
      cost,
      (ev.ms or 0) / 1000
    ),
      "block"
  end
end

--- Rebuild the tail text from a list of audit events (stream chunks
--- append verbatim; block events join with one blank line).
local function render_events(events)
  local parts, has = {}, false
  for _, ev in ipairs(events) do
    local text, kind = render_event(ev)
    if text then
      if kind == "stream" then
        parts[#parts + 1] = text
      else
        if has then
          parts[#parts + 1] = "\n"
        end
        parts[#parts + 1] = text .. "\n"
      end
      has = true
    end
  end
  return table.concat(parts)
end

--- Find a buffer by name, or create one (unlisted) with that name.
--- Reuse comes first: naming a fresh buffer identically to a leftover
--- would E95 (the chat buffer may have been wiped and reopened). Returns
--- the buffer and whether it was freshly created.
local function find_or_create_buffer(name, listed, scratch)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return b, false
    end
  end
  local b = vim.api.nvim_create_buf(listed, scratch)
  vim.api.nvim_buf_set_name(b, name)
  return b, true
end

local function ensure_tail(buf)
  local t = tails[buf]
  if t and vim.api.nvim_buf_is_valid(t.bufnr) then
    return t
  end
  local name = paths.tail_buf_name(buf)
  local tail = find_or_create_buffer(name, false, true) -- unlisted scratch: never in :ls or buffer pickers
  vim.bo[tail].bufhidden = "hide"

  t = { bufnr = tail, offset = 0, has_content = false }
  tails[buf] = t

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
  local lines = vim.split(render_events(events), "\n", { plain = true })
  vim.api.nvim_buf_set_lines(tail, 0, -1, false, lines)
  t.has_content = #lines > 1 or lines[1] ~= ""
  return t
end

--- Append an event to the audit log and render it into the tail buffer.
local function append_event(buf, ev)
  local t = ensure_tail(buf)
  audit_append(buf, ev)
  local text, kind = render_event(ev)
  if not text then
    return
  end
  if kind == "stream" then
    document.append_text(t.bufnr, text)
  else
    document.append_text(t.bufnr, (t.has_content and "\n" or "") .. text .. "\n")
  end
  t.has_content = true
  for _, w in ipairs(vim.fn.win_findbuf(t.bufnr)) do
    vim.api.nvim_win_set_cursor(w, { vim.api.nvim_buf_line_count(t.bufnr), 0 })
  end
end

--- Cap the raw tool output streamed into the live tail (and audit log)
--- per tool run. The returned tool result is already tail-truncated to
--- 50KB; the live tail must not accumulate the full log — a runaway
--- command writing gigabytes would otherwise balloon the tail buffer
--- (and audit log) and OOM the editor. 256KB is ample for watching
--- progress while keeping memory bounded.
local LIVE_OUTPUT_CAP = 256 * 1024

--- Append newly written bytes of the running tool's log to the tail
--- buffer (called on the spinner tick, on tool_end, and on process
--- exit). Defined via the forward declaration: the spinner ticks
--- before this section runs.
local function drain_tail(buf)
  local t, l = tails[buf], live[buf]
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
    append_event(buf, { type = "output", name = l.name, ts = os.date("%Y-%m-%dT%H:%M:%S"), data = data })
  elseif room <= 0 and stat.size > 0 and not l.truncated then
    l.truncated = true
    append_event(buf, { type = "output", name = l.name, ts = os.date("%Y-%m-%dT%H:%M:%S"), data = ("[live output truncated at %d bytes; remaining %d bytes not shown]\n"):format(LIVE_OUTPUT_CAP, stat.size - LIVE_OUTPUT_CAP) })
  end
end

state.drain_tail = drain_tail

--- Handle one `yap:event {json}` line from the binary's stderr.
local scratch_section_text, scratch_set_section, scratch_save

local function handle_event(buf, json_line)
  local ok, ev = pcall(vim.json.decode, json_line)
  if not ok or type(ev) ~= "table" then
    return
  end
  ev.ts = os.date("%Y-%m-%dT%H:%M:%S")
  if ev.type == "tool_start" and ev.log then
    live[buf] = { name = ev.name or "tool", log = ev.log, since = os.time(), out = 0 }
    local t = ensure_tail(buf)
    t.offset = 0
    append_event(buf, ev)
  elseif ev.type == "tool_end" then
    drain_tail(buf) -- the log is complete; capture the final bytes
    live[buf] = nil
    -- Go keeps the log for us; once drained, an untruncated one is gone
    -- (a truncated log stays: its result references it).
    if ev.log and not ev.truncated then
      vim.npcall(os.remove, ev.log)
    end
  elseif ev.type == "subagent_request" then
    start_subagent(buf, ev)
  elseif ev.type == "subagent_timeout" then
    local child = subagent_children[buf]
    if child then M.stop(child) end
  elseif ev.type == "approval_request" then
    append_event(buf, ev)
    local command = ev.command or ""
    local preview = command:gsub("%s+", " ")
    if #preview > 300 then
      preview = preview:sub(1, 300) .. "..."
    end
    local choice = vim.fn.confirm(("yap: run this?\n\n%s"):format(preview), "&Run\n&Deny", 1, "Warning")
    local approved = choice == 1
    local process = servers[buf]
    if process then
      process:write(vim.json.encode({ type = "approval_result", id = ev.id, approved = approved }) .. "\n")
    end
    append_event(buf, { type = "approval_result", id = ev.id, approved = approved, ts = os.date("%Y-%m-%dT%H:%M:%S") })
  elseif ev.type == "approval_timeout" then
    append_event(buf, ev)
  elseif ev.type == "tool_call" then
    -- quickfix is a frontend side effect: only a live tool_call event
    -- creates a list, so persisted tool blocks never replay on reopen.
    if ev.name == "quickfix" then
      local ok_qf, a = pcall(vim.json.decode, ev.args or "")
      if ok_qf and type(a) == "table" and type(a.entries) == "table" then
        local items = {}
        for _, entry in ipairs(a.entries) do
          table.insert(items, {
            filename = entry.file,
            lnum = entry.line,
            col = entry.column or 0,
            text = entry.text,
          })
        end
        -- ' ' creates a new stack entry: it replaces the visible list while
        -- preserving the previous one for :colder/:cnewer.
        vim.fn.setqflist({}, " ", { title = "Yap", context = { yap = true }, items = items })
      end
    elseif ev.name == "close_session" then
      -- Defer to turn completion so the reply streams out and the session
      -- file is saved before the buffer is wiped (complete() below).
      close_after_turn[buf] = true
    end
    append_event(buf, ev) -- full arguments for every tool (bash renders via tool_start)
  elseif ev.type == "tool_result" then
    append_event(buf, ev) -- full result; bash output already streamed above
  elseif ev.type == "retry" then
    append_event(buf, ev) -- a transient generation error was retried
  elseif ev.type == "steer" then
    if steer[buf] == ev.text then
      steer[buf] = nil -- delivered: remove only the matching live draft
      local scratch = vim.b[buf].yap_scratch
      if scratch and vim.api.nvim_buf_is_valid(scratch)
          and scratch_section_text(scratch, "steer") == ev.text then
        scratch_set_section(scratch, "steer", {})
        scratch_save(scratch)
      end
    end
    append_event(buf, ev) -- audit trail: a steering message landed mid-turn
  elseif ev.type == "tool_text_warning" then
    append_event(buf, ev) -- the model emitted a tool call as text; nothing ran
  elseif ev.type == "turn_end" then
    last_turn[buf] = ev -- for the User YapTurnDone event on exit
    -- Fold this turn into the session's all-time totals (seeded from the
    -- audit log on open; this keeps the in-memory copy in step with it).
    local su = vim.b[buf].yap_session_usage or { prompt = 0, completion = 0 }
    su.prompt = su.prompt + (ev.prompt or 0)
    su.completion = su.completion + (ev.completion or 0)
    if ev.cost then
      su.cost = (su.cost or 0) + ev.cost
    end
    vim.b[buf].yap_session_usage = su
    append_event(buf, ev)
  end
end

--- :YapClear [keep] — replace the bodies of all but the last `keep`
--- (default 2) yap:tool regions with a placeholder; the full output
--- stays in the audit log. Headers (flattened into the model's transcript)
--- and yap:ui diffs stay. This is the one sanctioned rewrite of
--- existing lines (R16): the user owns the document, and clearing old
--- tool output is what keeps long sessions inside the context window.
function M.clear(buf, keep)
  buf = (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
  if running[buf] then
    vim.notify("yap: send in flight, not clearing", vim.log.levels.WARN)
    return
  end
  keep = keep or 2
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- Map tool-call ids to their JSONL line range (tool_call → tool_result)
  -- so each placeholder can point at the exact lines it replaced.
  local by_id = {}
  local apath = paths.audit_path(buf)
  if vim.fn.filereadable(apath) == 1 then
    for n, line in ipairs(vim.fn.readfile(apath)) do
      if line ~= "" then
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" and ev.id then
          local entry = by_id[ev.id]
          if not entry then
            entry = {}
            by_id[ev.id] = entry
          end
          entry.first = entry.first or n
          entry.last = n
        end
      end
    end
  end
  local function ref_for(id)
    local entry = id and by_id[id] or nil
    if entry and entry.last then
      if entry.first and entry.first ~= entry.last then
        return ("%s:%d-%d"):format(vim.fn.fnamemodify(apath, ":~"), entry.first, entry.last)
      end
      return ("%s:%d"):format(vim.fn.fnamemodify(apath, ":~"), entry.last)
    end
    return vim.fn.fnamemodify(apath, ":~") .. ":?"
  end
  -- collect tool regions as { first body line, last body line, header } (1-based,
  -- inclusive); the body runs from after the header to the yap:ui
  -- opener or the region closer
  local regions = {}
  local i = 1
  while i <= #lines do
    local body_start, header
    if lines[i]:match("^<!%-%- yap:tool .+ %-%->%s*$") then
      header = lines[i]:match("^<!%-%- yap:tool (.+) %-%->%s*$")
      body_start = i + 1 -- single-line header
    elseif lines[i]:match("^<!%-%- yap:tool%s*$") then
      local acc = {}
      local j = i + 1 -- multi-line header: body after its closing -->
      while j <= #lines and not lines[j]:match("^%-%->%s*$") do
        acc[#acc + 1] = lines[j]
        j = j + 1
      end
      header = table.concat(acc, "\n")
      body_start = j + 1
    end
    if body_start then
      local j = body_start
      while j <= #lines and not lines[j]:match("^<!%-%- yap:ui") and not lines[j]:match("^<!%-%- /yap:tool") do
        j = j + 1
      end
      table.insert(regions, { body_start, j - 1, header = header })
      i = j
    else
      i = i + 1
    end
  end
  local cleared = 0
  for r = 1, #regions - keep do
    local s, e = regions[r][1], regions[r][2]
    if e >= s and not lines[s]:match("^%[output cleared") then
      local id
      local ok_h, h = pcall(vim.json.decode, regions[r].header or "")
      if ok_h and type(h) == "table" then
        id = h.id
      end
      local placeholder = ("[output cleared — full output in the audit log: %s]"):format(ref_for(id))
      vim.api.nvim_buf_set_lines(buf, s - 1, e, false, { placeholder })
      cleared = cleared + 1
      local delta = (e - s + 1) - 1 -- replaced that many lines with one
      for r2 = r + 1, #regions do
        regions[r2][1], regions[r2][2] = regions[r2][1] - delta, regions[r2][2] - delta
      end
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
  if cleared > 0 then
    require("harness.session").save(buf)
  end
end

--- The compaction prompt: a `compact` template in templates_dir overrides
--- the built-in default (compaction is the template mechanism applied,
--- R18). Returns trimmed body lines, never a leading # @role heading.
local function compact_prompt_lines()
  local lines = require("harness.template").named_lines("compact")
  if not lines then
    lines = vim.split(
      "Summarize the conversation above into a compact markdown summary that\n"
        .. "preserves all facts, decisions, open todos, and current file state.\n"
        .. "I will use that summary to continue the conversation with full context.",
      "\n",
      { plain = true }
    )
  end
  vim.list_extend(lines, {
    "Do not use the colon character anywhere in the summary. Avoid YAML/frontmatter delimiters, Markdown headings, code fences, and HTML comments. Use simple prose or basic bullets so the summary stays safe for Markdown Tree-sitter parsing.",
  })
  return lines
end

--- :YapCompact — compaction as the visible, editable recipe, automated:
--- insert the compact prompt, send it, then offer to delete the superseded
--- history once the summary has streamed in. The summary stays a visible
--- # @assistant turn; the deletion is an ordinary (undoable) buffer edit,
--- never a hidden archive (see |yap-compact|).
function M.compact()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.b[buf].yap then
    vim.notify("yap: not a yap buffer", vim.log.levels.WARN)
    return
  end
  if running[buf] then
    vim.notify("yap: send in flight, not compacting", vim.log.levels.WARN)
    return
  end
  require("harness.template").append_as_block(buf, compact_prompt_lines())
  vim.b[buf].yap_compact_pending = true
  M.send()
end

--- Offer to drop the history the summary superseded (asked once the
--- summary has finished streaming; the summary is never touched).
function M.compact_offer(buf)
  vim.ui.select({ "Delete history", "Keep history" }, {
    prompt = "yap: compact — delete the superseded history? (the summary stays)",
  }, function(choice)
    if choice == "Delete history" then
      M.compact_delete(buf)
    end
  end)
end

--- Delete every message between the system block and the final summary
--- (the last # @assistant block), leaving frontmatter + system block +
--- summary + the trailing # @user prompt. Blank-line separation is R7.
function M.compact_delete(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ai
  for i = #lines, 1, -1 do
    if lines[i]:match("^# @assistant%s*$") then
      ai = i
      break
    end
  end
  if not ai then
    vim.notify("yap: no assistant summary to keep", vim.log.levels.WARN)
    return
  end
  -- Keep frontmatter + the system block: the system block ends at the
  -- first heading after # @system; with no system block, keep only the
  -- frontmatter (everything before the first heading).
  local se = 0
  for i = 1, #lines do
    if lines[i]:match("^# @system%s*$") then
      for j = i + 1, #lines do
        if lines[j]:match(HEAD) then
          se = j - 1
          break
        end
      end
      if se == 0 then
        se = #lines -- system block runs to the end (no later heading)
      end
      break
    elseif lines[i]:match(HEAD) then
      se = i - 1 -- no system block: keep frontmatter only
      break
    end
  end
  while se > 0 and lines[se]:match("^%s*$") do
    se = se - 1
  end
  local kept = {}
  for i = 1, se do
    kept[#kept + 1] = lines[i]
  end
  kept[#kept + 1] = "" -- one blank line between system and summary (R7)
  for i = ai, #lines do
    kept[#kept + 1] = lines[i]
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, kept)
  require("harness.session").save(buf)
end

-- The chat window each open drawer is anchored to, so closing the drawer
-- returns the cursor to the window it was toggled from (never stranded on
-- a dead window or jumped to an unrelated one).
local drawer_anchor = {} -- drawer bufnr -> owner window id

--- Open or close a fixed-height drawer below the chat window. This is the
--- ONE toggle pattern for the audit-log tail and the scratch queue: a
--- single persistent buffer, never duplicated, always a full-width bottom
--- split, and closed back to the window it was toggled from. Anchoring the
--- split to a window showing `owner` is what keeps the drawer full-width
--- when the chat shares a vertical split — a bare `belowright split` would
--- carve a half-width jotter out of the current pane.
local function toggle_drawer(owner, bufnr, height)
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins > 0 then
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    local anchor = drawer_anchor[bufnr]
    if anchor and vim.api.nvim_win_is_valid(anchor) then
      vim.api.nvim_set_current_win(anchor)
    end
    drawer_anchor[bufnr] = nil
    return false
  end

  local owner_wins = vim.fn.win_findbuf(owner)
  local cur = vim.api.nvim_get_current_win()
  local anchor
  if vim.tbl_contains(owner_wins, cur) then
    anchor = cur -- stay where the user toggled from
  elseif #owner_wins > 0 and vim.api.nvim_win_is_valid(owner_wins[1]) then
    anchor = owner_wins[1]
  end
  if anchor and vim.api.nvim_win_is_valid(anchor) then
    vim.api.nvim_set_current_win(anchor)
  end
  vim.cmd("botright " .. height .. "split")
  vim.api.nvim_win_set_buf(0, bufnr)
  drawer_anchor[bufnr] = anchor
  return true
end

local function close_drawer_window(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      if #vim.api.nvim_list_wins() > 1 then
        vim.api.nvim_win_close(win, true)
      else
        -- Neovim cannot close the last window; replace its view while keeping
        -- the file-backed drawer buffer available to reopen later.
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
      end
    end
  end
  drawer_anchor[buf] = nil
end

local function close_session_drawers(buf)
  local scratch = vim.b[buf].yap_scratch
  if scratch and vim.api.nvim_buf_is_valid(scratch) then
    close_drawer_window(scratch)
  end
  local tail = tails[buf]
  if tail and vim.api.nvim_buf_is_valid(tail.bufnr) then
    close_drawer_window(tail.bufnr)
  end
end

--- Open the session's tail buffer (:YapLive): one persistent rendering
--- of the audit log, not a new terminal per call. Opens even before any
--- tool has run (an empty tail that fills as tools execute).
function M.live(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  for chat, t in pairs(tails) do
    if t.bufnr == buf then
      toggle_drawer(chat, buf, 12)
      return
    end
  end
  local t = ensure_tail(buf)
  if not toggle_drawer(buf, t.bufnr, 12) then
    return
  end
  if M.config.keymaps.live ~= "" then
    vim.keymap.set("n", M.config.keymaps.live, function()
      M.live(t.bufnr)
    end, { buffer = t.bufnr, silent = true, desc = "yap: toggle live tool output" })
  end
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(t.bufnr), 0 })
end

--- The queue file is a sibling of the session file, sharing its basename
--- with a `.queue` extension, so it lives in the sessions dir but
--- session.list()'s `*.md` glob never mistakes it for a session.
local function queue_path(buf)
  return paths.queue_path(buf)
end

--- Drag the queue file and buffer along after a `:file` rename of the
--- session, the same way the audit log follows (see audit_follow).
local function queue_follow(buf, scratch)
  local want = queue_path(buf)
  local name = vim.api.nvim_buf_get_name(scratch)
  if name == want then
    return
  end
  if name ~= "" and vim.fn.filereadable(name) == 1 and vim.fn.filereadable(want) == 0 then
    os.rename(name, want)
  end
  vim.api.nvim_buf_set_name(scratch, want)
end

--- Scratch sections are explicit so notes never become an accidental prompt.
--- Queue entries are one non-empty line each; a steer is one multiline body.
local function scratch_section(scratch, name)
  local lines = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
  local heading
  for i, line in ipairs(lines) do
    local role = line:match("^# @([%a]+)%s*$")
    if role == name then
      heading = i
      break
    end
  end
  if not heading then
    return nil
  end
  local finish = #lines
  for i = heading + 1, #lines do
    if lines[i]:match("^# @[%a]+%s*$") then
      finish = i - 1
      break
    end
  end
  return heading, finish, lines
end

local function scratch_section_lines(scratch, name)
  local heading, finish, lines = scratch_section(scratch, name)
  if not heading then
    return {}
  end
  local body = {}
  for i = heading + 1, finish do
    body[#body + 1] = lines[i]
  end
  while #body > 0 and body[1]:match("^%s*$") do table.remove(body, 1) end
  while #body > 0 and body[#body]:match("^%s*$") do table.remove(body) end
  return body
end

scratch_set_section = function(scratch, name, body)
  local heading, finish = scratch_section(scratch, name)
  if not heading then
    return
  end
  vim.api.nvim_buf_set_lines(scratch, heading, finish, false, body)
end

scratch_section_text = function(scratch, name)
  return table.concat(scratch_section_lines(scratch, name), "\n")
end

local function scratch_take_queue_item(scratch)
  local heading, finish, lines = scratch_section(scratch, "queue")
  if not heading then
    return nil
  end
  for i = heading + 1, finish do
    if lines[i]:match("%S") then
      local item = lines[i]:gsub("^%s+", ""):gsub("%s+$", "")
      vim.api.nvim_buf_set_lines(scratch, i - 1, i, false, {})
      return item
    end
  end
  return nil
end

--- Write the live scratch buffer after a consumed item is removed.
scratch_save = function(scratch)
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    return
  end
  if vim.api.nvim_buf_get_name(scratch) == "" then
    return
  end
  vim.api.nvim_buf_call(scratch, function()
    vim.cmd("silent noautocmd keepjumps write!")
  end)
end

local function cancel_steer(buf)
  steer[buf] = nil
  local proc = running[buf]
  if not proc then
    return
  end
  local ok = pcall(function()
    proc:write(vim.json.encode({ type = "unsteer" }) .. "\n")
  end)
  if not ok then
    vim.notify("yap: could not cancel steer (backend gone)", vim.log.levels.WARN)
  end
end

--- Steer the running turn using the current # @steer body. The text stays in
--- the live buffer until the backend confirms delivery, so it can be edited
--- or removed while waiting for the next model boundary.
function M.steer(buf, text)
  if text == "" then
    cancel_steer(buf)
    return true
  end
  if steer[buf] == text then
    return true
  end
  local proc = running[buf]
  local ok = pcall(function()
    proc:write(vim.json.encode({ type = "steer", text = text }) .. "\n")
  end)
  if not ok then
    vim.notify("yap: could not steer (backend gone)", vim.log.levels.WARN)
    return false
  end
  steer[buf] = text
  vim.notify("yap: steering — remove/edit # @steer to retract or revise", vim.log.levels.INFO)
  return true
end

local function sync_scratch_steer(owner, scratch)
  local pending = steer[owner]
  if not pending or not M.is_running(owner) then
    return
  end
  local current = scratch_section_text(scratch, "steer")
  if current ~= pending then
    M.steer(owner, current)
  end
end

local function scratch_dispatch_next(owner)
  if not vim.api.nvim_buf_is_valid(owner) or M.is_running(owner) then
    return false
  end
  local scratch = vim.b[owner].yap_scratch
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    return false
  end
  local item = scratch_take_queue_item(scratch)
  if not item then
    return false
  end
  scratch_save(scratch)
  document.append_message(owner, "user", vim.split(item, "\n", { plain = true }))
  M.send(owner)
  return true
end

--- <C-s> dispatches by state: while running it submits the # @steer body;
--- while idle it consumes the next one-line # @queue item. Notes are inert.
function M.scratch_send(scratch)
  scratch = scratch or vim.api.nvim_get_current_buf()
  local owner = vim.b[scratch].yap_owner
  if not (owner and vim.api.nvim_buf_is_valid(owner)) then
    vim.notify("yap: scratch has no chat buffer", vim.log.levels.WARN)
    return
  end

  if M.is_running(owner) then
    local text = scratch_section_text(scratch, "steer")
    if text == "" and not steer[owner] then
      vim.notify("yap: # @steer is empty", vim.log.levels.WARN)
      return
    end
    M.steer(owner, text)
    return
  end

  if not scratch_dispatch_next(owner) then
    vim.notify("yap: # @queue is empty", vim.log.levels.WARN)
  end
end


local function scratch_heading(line)
  return line:match("^# @notes%s*$") or line:match("^# @steer%s*$") or line:match("^# @queue%s*$")
end

function M.scratch_foldexpr(lnum)
  local current = vim.fn.getline(lnum)
  if scratch_heading(current) then
    return ">1"
  end
  for row = lnum - 1, 1, -1 do
    if scratch_heading(vim.fn.getline(row)) then
      return "1"
    end
  end
  return "0"
end

--- Toggle the session's scratch buffer (<leader>s): a fixed-height jotter
--- opened below the chat window. It is a real, file-backed buffer — a
--- sibling `*.queue` file of the session — so `:write` saves it and an
--- unsaved queue prompts on exit like any other modified buffer. It is a
--- quick "queue" for agent tasks, never part of the conversation.
local SCRATCH_HEIGHT = 8

function M.scratch_toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.b[buf].yap then
    vim.notify("yap: not a yap buffer", vim.log.levels.WARN)
    return
  end

  local scratch = vim.b[buf].yap_scratch
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    -- Reuse a leftover queue buffer from a wiped-and-reopened session,
    -- otherwise create a file-backed buffer and load the saved queue.
    local want = queue_path(buf)
    local created
    scratch, created = find_or_create_buffer(want, false, false) -- unlisted, file-backed
    if created and vim.fn.filereadable(want) == 1 then
      vim.api.nvim_buf_set_lines(scratch, 0, -1, false, vim.fn.readfile(want))
    end
    local lines = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
    local found = {}
    for _, line in ipairs(lines) do
      local role = line:match("^# @([%a]+)%s*$")
      if role then found[role] = true end
    end
    if not found.notes and not found.steer and not found.queue then
      local legacy = (#lines == 1 and lines[1] == "") and {} or lines
      local migrated = { "# @notes", "", "# @steer", "", "# @queue" }
      vim.list_extend(migrated, legacy)
      vim.api.nvim_buf_set_lines(scratch, 0, -1, false, migrated)
    else
      local missing = {}
      for _, role in ipairs({ "notes", "steer", "queue" }) do
        if not found[role] then
          missing[#missing + 1] = ""
          missing[#missing + 1] = "# @" .. role
        end
      end
      if #missing > 0 then
        local endline = vim.api.nvim_buf_line_count(scratch)
        vim.api.nvim_buf_set_lines(scratch, endline, endline, false, missing)
      end
    end
    vim.bo[scratch].bufhidden = "hide"
    vim.bo[scratch].buflisted = false
    vim.b[buf].yap_scratch = scratch
    vim.b[scratch].yap_owner = buf
    if not vim.b[scratch].yap_steer_watch then
      vim.b[scratch].yap_steer_watch = true
      vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = scratch,
        callback = function()
          local owner = vim.b[scratch].yap_owner
          if owner and vim.api.nvim_buf_is_valid(owner) then
            sync_scratch_steer(owner, scratch)
          end
        end,
      })
    end
    if M.config.keymaps.scratch ~= "" then
      vim.keymap.set("n", M.config.keymaps.scratch, function()
        M.scratch_toggle(buf)
      end, { buffer = scratch, silent = true, desc = "yap: toggle scratch" })
    end
    if M.config.keymaps.send ~= "" then
      vim.keymap.set("n", M.config.keymaps.send, function()
        M.scratch_send(scratch)
      end, { buffer = scratch, silent = true, desc = "yap: send scratch" })
      vim.keymap.set("i", M.config.keymaps.send, function()
        vim.cmd.stopinsert()
        M.scratch_send(scratch)
      end, { buffer = scratch, silent = true, desc = "yap: send scratch" })
      vim.keymap.set("x", M.config.keymaps.send, function()
        M.scratch_send(scratch)
      end, { buffer = scratch, silent = true, desc = "yap: send scratch selection" })
    end
  else
    vim.b[scratch].yap_owner = buf
  end

  queue_follow(buf, scratch) -- session renamed? drag the queue file along

  -- Toggle: a visible queue closes back to the chat; an invisible one opens
  -- full-width below it (see toggle_drawer).
  if not toggle_drawer(buf, scratch, SCRATCH_HEIGHT) then
    return
  end
  vim.wo.winfixheight = true
  vim.wo.winbar = "" -- a plain jotter, not a yap dashboard
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require'harness'.scratch_foldexpr(v:lnum)"
  vim.wo.foldtext = ""
  vim.wo.foldlevel = 99
  vim.wo.foldenable = true
end

--- Record a backend error: notify, persist it in the winbar, and leave a
--- parse-excluded marker in the buffer as a record.
local function report_error(buf, err)
  errors[buf] = err
  -- The marker is an HTML comment: neutralize any `-->` in the error
  -- text so it can't close the comment early for markdown renderers.
  local block = { "<!-- yap:error" }
  vim.list_extend(block, vim.split(err:gsub("%-%->", "-- >"), "\n", { plain = true }))
  table.insert(block, "-->")
  document.append_block(buf, block)
  vim.notify("yap: " .. err, vim.log.levels.ERROR)
end

--- Close dangling regions left by an interrupted stream. :YapStop
--- kills the binary, which exits without emitting the closers for
--- whatever it was mid-way through: a thinking comment (close with
--- `-->`), a multi-line tool header (an unterminated comment: `-->`,
--- then the region closer), or a tool region whose header landed but
--- whose result didn't (`<!-- /yap:tool -->`). Two flags suffice:
--- model text/thinking and tool regions never interleave. Idempotent;
--- cheap enough to run on every process exit.
local function repair_stream_tail(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local in_tool, comment_open = false, false
  for _, line in ipairs(lines) do
    if line:match("^<!%-%- /yap:tool") then
      in_tool = false
    elseif line:match("^<!%-%- yap:tool%s*$") then
      in_tool, comment_open = true, true -- multi-line header comment
    elseif line:match("^<!%-%- yap:tool .+ %-%-%>%s*$") then
      in_tool = true -- single-line header: comment closed, region open
    elseif line:match("^<!%-%- yap:%a+%s*$") then
      comment_open = true
    elseif line == "-->" then
      comment_open = false
    end
  end
  local block = {}
  if comment_open then
    table.insert(block, "-->")
  end
  if in_tool then
    table.insert(block, "<!-- /yap:tool -->")
  end
  if #block > 0 then
    vim.api.nvim_buf_set_lines(buf, #lines, #lines, false, block)
  end
end

-- Latest description request per buffer, so a slow earlier summary cannot
-- clobber a newer one (send and turn-completion refreshes can overlap).
local description_seq = {}
local description_started = {}

-- Routine commit/close requests should not become the session's title when
-- an earlier user request explains what the work was actually about. Tool
-- calls and results are assistant transcript text, not user intent, so never
-- send them to the title model.
local function title_messages(messages)
  local user_indices = {}
  for i, message in ipairs(messages) do
    if message.role == "user" then
      user_indices[#user_indices + 1] = i
    end
  end
  if #user_indices == 0 then
    return {}, false, false
  end

  local latest = user_indices[#user_indices]
  local earlier_user = #user_indices > 1
  local text = messages[latest].content:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local lower = text:lower()
  local replacement
  local housekeeping_only = false
  if lower:match("^commit changes from this session") or lower:match("^commit( and close)?[.!]?$") then
    replacement = nil
    housekeeping_only = true
  elseif earlier_user then
    replacement = lower:match("^(.-)%s+commit and close[.!]?$")
    if replacement then
      replacement = replacement:gsub("%s+$", "")
    end
  end

  local filtered = {}
  for _, i in ipairs(user_indices) do
    if i ~= latest then
      filtered[#filtered + 1] = messages[i]
    elseif replacement and replacement ~= "" then
      filtered[#filtered + 1] = { role = "user", content = replacement }
    elseif not housekeeping_only then
      filtered[#filtered + 1] = messages[i]
    end
  end
  return filtered, housekeeping_only or replacement ~= nil, housekeeping_only
end

local function current_description(buf)
  local e = frontmatter_end(buf)
  if not e then
    return ""
  end
  local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
  return fm and fm.description or ""
end

--- Generate or refresh the session description shown in the winbar and
--- session picker. `kind` selects the model and what it summarizes:
---   "user"   — smallest model, only the first useful request (runs once)
---   "answer" — bigger model, the ordered user-request history (runs after turns)
local function refresh_description(buf, kind, messages)
  local combo, system, content
  local title_input, housekeeping = title_messages(messages or document.parse_buffer(buf))
  if kind == "user" then
    -- Generate an instant label only once, from the session's first useful
    -- request. Later turns are summarized by the whole-session stage below.
    if current_description(buf) ~= "" or description_started[buf] or (housekeeping and #title_input == 0) then
      return
    end
    combo = M.config.description_model
    system = [[Write a short title for the user's request below.

Rules:
- 2-5 words, a specific noun phrase, not a sentence
- No leading "The user", no "how to", no trailing period
- No colon in the title (it breaks the YAML frontmatter)
- Example: "Add websearch tool", "Fix fold lag on streaming"

Return only the title.]]
    for _, message in ipairs(title_input) do
      if message.role == "user" then
        content = message.content
        break
      end
    end
    if not content or content == "" then
      return
    end
  else
    if #title_input == 0 then
      return
    end
    combo = M.config.description_answer_model
    system = [[Write a short session title centered on the overall work, so the session is easy to find later.

The input is the user's requests in order. The first request anchors the session's main goal; later requests may refine or extend it. Summarize the overall work, not just the final request or workflow.

Rules:
- 2-6 words, a specific noun phrase, not a sentence, no trailing period
- No "session", "conversation", "the user", "about"
- Prefer "Subject – change" so titles stay distinct across sessions in the same project
- No colon in the title — it breaks the YAML frontmatter
- Routine commit/close instructions are housekeeping, not the session goal
- Never title from code, logs, or command output; do not use Markdown fences
- Example: "Fold lag – cache per changedtick"

Return only the title.]]
    local requests = {}
    for _, message in ipairs(title_input) do
      requests[#requests + 1] = message.content
    end
    local follow_ups = {}
    for i = 2, #requests do
      follow_ups[#follow_ups + 1] = requests[i]
    end
    content = vim.json.encode({ initial_request = requests[1], follow_up_requests = follow_ups })
  end
  if not combo or combo == "" then
    return
  end
  local provider, model = combo:match("^([%w_.:%-]+)/([%w_.:%-]+)$")
  if not provider then
    return
  end
  local seq = (description_seq[buf] or 0) + 1
  description_seq[buf] = seq
  if kind == "user" then
    description_started[buf] = true
  end
  local payload = vim.json.encode({
    messages = {
      { role = "system", content = system },
      { role = "user", content = content },
    },
  })
  vim.system(
    { M.config.bin, "send", "--provider", provider, "--model", model },
    { stdin = payload, text = true },
    vim.schedule_wrap(function(result)
      if not vim.api.nvim_buf_is_valid(buf) or description_seq[buf] ~= seq then
        return
      end
      if result.code ~= 0 then
        return
      end
      local description = (result.stdout or "")
        :gsub("<!%-%-.-%-%->", "")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
        :gsub(":%s+", " – ")
      if description == "" or description:find("`", 1, true) then
        return
      end
      -- The prompts ask for a 2-6 word phrase, but a verbose model can
      -- still return a paragraph; hard-cap it so the frontmatter and
      -- picker stay readable. (No max_tokens cap: reasoning models spend
      -- the whole budget on reasoning and return an empty completion.)
      if #description > 60 then
        description = description:sub(1, 59):gsub("%s+%S*$", "") .. "…"
      end
      local e = frontmatter_end(buf)
      if not e then
        return
      end
      local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
      if not fm then
        return
      end
      local block = frontmatter.render(fm.provider, fm.model, fm.models, fm.created_at, description, fm.role, fm.tools, fm.subagents, fm.updated_at, fm.turns)
      vim.api.nvim_buf_set_lines(buf, 0, e, false, block)
      require("harness.session").save(buf)
    end)
  )
end

--- Every stream exit, including errors and :YapStop, hands the buffer back
--- to the user in the same writable shape as a successful turn.
local function close_stream(buf)
  repair_stream_tail(buf)
  document.append_block(buf, { "# @user", "" })
  awaiting[buf] = true
  require("harness.session").save(buf)
  if subagent_done[buf] then
    local done = subagent_done[buf]
    subagent_done[buf] = nil
    done(false)
  end
end

--- Serialize the current buffer and stream the assistant reply into it.
function M.send(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if running[buf] then
    vim.notify("yap: already streaming (stop with :YapStop)", vim.log.levels.WARN)
    return
  end
  -- A close request is scoped to the turn that made it: a stale flag from
  -- a previous errored or stopped turn must not close a later turn.
  close_after_turn[buf] = nil

  local messages = document.parse_buffer(buf)
  -- The harness always prepends its own boilerplate, then the
  -- request-scoped cwd: neither is stored in the buffer, so the visible
  -- session stays clean and :cd takes effect on the very next turn.
  table.insert(messages, 1, { role = "system", content = yap_about() })
  table.insert(messages, 2, {
    role = "system",
    content = "Current Neovim working directory: " .. vim.fn.getcwd(),
  })
  if #messages == 0 then
    vim.notify("yap: nothing to send (write under a # @user heading)", vim.log.levels.WARN)
    return
  end

  -- Label the session from the latest user message immediately (smallest
  -- model); the final whole-session title arrives after the answer.
  refresh_description(buf, "user", messages)

  errors[buf] = nil
  awaiting[buf] = nil
  -- provider/model come from the buffer vars (set by :Yap /
  -- :YapChangeModel), falling back to config; sync them so the winbar
  -- and this send agree.
  local provider, model = util.current_combo(buf)
  vim.b[buf].yap_provider = provider
  vim.b[buf].yap_model = model

  -- A window already watching the end keeps watching it while the reply
  -- streams (follow_windows); one parked elsewhere is not dragged along.
  local follow = document.following_windows(buf)
  local expected_follow = {}
  local function sync_followers()
    document.sync_followers(buf, follow, expected_follow)
  end
  local function follow_tail()
    document.follow_windows(buf, follow, expected_follow)
  end
  -- New assistant output adopts the current view: in view 1 it stays
  -- folded; in views 2/3 it is visible as it arrives.
  document.append_block(buf, { "# @assistant", "" })
  follow_tail()
  -- Sends never touch existing fold state or rewrite existing lines: the
  -- buffer is always in its final format, streaming only appends at the end,
  -- and new folds adopt the view's 'foldlevel' as they appear.
  winbar.spinner_start()

  local process = servers[buf]
  if not process then
    local partial = ""
    local stderr_partial = ""
    local stderr_chunks = {}
    local status, barrier
    -- Coalesce rapid per-token stdout flushes into one buffer edit per
    -- ~STREAM_FLUSH_MS: block parsing is O(n) per edit, so batching keeps a
    -- fast stream smooth on large sessions instead of stalling per token.
    -- This is a THROTTLE: the timer starts on the first token of a batch.
    -- Only incomplete structural prefixes wait for classification; ordinary
    -- prose flushes every tick even under continuous token flow.
    local STREAM_FLUSH_MS = 30
    local pending = ""
    local flush_timer = nil
    local function flush_pending(final)
      if pending == "" then
        return
      end
      local data = pending
      pending = ""
      if not final then data, pending = document.split_stream_tail(buf, data) end
      if data == "" then return end
      sync_followers()
      document.append_text(buf, data)
      follow_tail()
    end
    local function on_flush_tick(timer)
      if flush_timer ~= timer then return end -- a final flush cancelled this tick
      flush_timer = nil
      timer:stop()
      timer:close()
      flush_pending()
    end
    -- uv timer callbacks run in a fast event context; schedule_wrap escapes
    -- it so nvim_buf_set_text is legal inside flush_pending.
    local on_flush_tick_wrapped = vim.schedule_wrap(on_flush_tick)
    local function finish_flush()
      if flush_timer then
        flush_timer:stop()
        flush_timer:close()
        flush_timer = nil
      end
      flush_pending(true)
    end
    stream_flush[buf] = finish_flush
    local function append(data)
      if data == "" then return end
      pending = pending .. data
      if not flush_timer then
        local timer = vim.uv.new_timer()
        flush_timer = timer
        timer:start(STREAM_FLUSH_MS, 0, function() on_flush_tick_wrapped(timer) end)
      end
    end
    local function route_event(ev)
      sync_followers()
      handle_event(buf, ev)
      follow_tail()
    end
    local function complete(result)
      status, barrier = nil, false
      finish_flush()
      sync_followers()
      running[buf] = nil
      stderr_chunks = {}
      local compact = vim.b[buf].yap_compact_pending
      vim.b[buf].yap_compact_pending = nil
      local l = live[buf]
      drain_tail(buf) -- final bytes; a killed tool never sent tool_end
      if l then
        live[buf] = nil
        vim.npcall(os.remove, l.log) -- a killed tool leaves a temp log behind
      end
      winbar.spinner_stop_if_idle()
      repair_stream_tail(buf)
      if not result.ok then
        local err = result.error or table.concat(stderr_chunks, "\n"):gsub("%s+$", "")
        report_error(buf, err ~= "" and err or "backend exited")
        close_stream(buf)
        follow_tail()
        close_if_requested(buf)
        return
      end
      consume_usage(buf)
      -- The binary can complete "successfully" with an embedded error
      -- marker (e.g. empty completion, max tool iterations): surface it.
      do
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for i = #lines, 1, -1 do
          local l = lines[i]
          if l:match("^# @%a+") then
            break
          end
          local err = l:match("^<!%-%- yap:error$") and lines[i + 1]
          if err then
            errors[buf] = err
            vim.notify("yap: " .. err, vim.log.levels.WARN)
            break
          end
        end
      end
      -- A steering message that arrived after the turn's last poll point is
      -- still pending: degrade it to a follow-up — fill the trailing
      -- `# @user` prompt with it and start a new turn below.
      local steer_text = steer[buf]
      steer[buf] = nil
      local scratch = vim.b[buf].yap_scratch
      if steer_text and scratch and vim.api.nvim_buf_is_valid(scratch)
          and scratch_section_text(scratch, "steer") == steer_text then
        scratch_set_section(scratch, "steer", {})
        scratch_save(scratch)
      end
      document.append_block(buf, { "# @user", "" })
      if steer_text then
        document.append_message(buf, "user", vim.split(steer_text, "\n", { plain = true }))
      end
      follow_tail()
      awaiting[buf] = true
      require("harness.session").save(buf)
      if subagent_done[buf] then
        local done = subagent_done[buf]
        subagent_done[buf] = nil
        done(not errors[buf])
      end
      refresh_description(buf, "answer")
      audit_follow(buf) -- first save named the session; rename the log to match
      -- A completed turn is a first-class event (herdr's "working → blocked
      -- → idle" notification). Fire it once the buffer is in its final state
      -- so handlers see the appended `# @user` and the saved session.
      vim.api.nvim_exec_autocmds("User", {
        pattern = "YapTurnDone",
        modeline = false,
        data = { buf = buf, turn = last_turn[buf] },
      })
      if compact then
        M.compact_offer(buf)
      end
      if steer_text then
        -- A pending steer wins over close_session (the user's later word
        -- outranks the agent's). Re-send as a fresh turn once the buffer
        -- is fully in its final state.
        close_after_turn[buf] = nil
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(buf) then
            return
          end
          M.send(buf)
        end)
      else
        vim.schedule(function()
          scratch_dispatch_next(buf)
        end)
      end
      -- close_session is a frontend side effect (like quickfix): the agent
      -- asked to end the session, so once the turn is fully done and the
      -- session file is saved, wipe the buffer. The BufWipeout autocmd in
      -- setup() tears down this buffer's serve backend.
      close_if_requested(buf)
    end
    local handle
    local ok, started = pcall(vim.system, { M.config.bin, "serve" }, {
      stdin = true,
      text = true,
      stdout = vim.schedule_wrap(function(_, data)
        if not data or servers[buf] ~= handle then return end
        partial = partial .. data
        while partial ~= "" do
          if partial:sub(1, 1) == "\30" then
            local i = partial:find("\n", 1, true)
            if not i then break end
            local line = partial:sub(2, i - 1)
            partial = partial:sub(i + 1)
            local status_line = line:match("^yap:turn_end (.+)$")
            local parsed, result = pcall(vim.json.decode, status_line or "")
            if status_line and parsed and type(result) == "table" and type(result.ok) == "boolean" then
              status = result
              if running[buf] and barrier then complete(result) end
            else
              append("?" .. line .. "\n")
            end
          else
            local i = partial:find("\30", 1, true)
            if i then
              append(partial:sub(1, i - 1))
              partial = partial:sub(i)
            else
              append(partial)
              partial = ""
            end
          end
        end
      end),
      stderr = vim.schedule_wrap(function(_, data)
        if not data or servers[buf] ~= handle then return end
        stderr_partial = stderr_partial .. data
        while true do
          local i = stderr_partial:find("\n", 1, true)
          if not i then break end
          local line = stderr_partial:sub(1, i - 1)
          stderr_partial = stderr_partial:sub(i + 1)
          local ev = line:match("^yap:event (.+)$")
          if ev then
            local parsed, event = pcall(vim.json.decode, ev)
            if parsed and event.type == "turn_complete" then
              barrier = true
              if running[buf] and status then complete(status) end
            else
              route_event(ev)
            end
          else
            table.insert(stderr_chunks, line)
          end
        end
      end),
    }, vim.schedule_wrap(function(result)
      if servers[buf] ~= handle then return end
      servers[buf] = nil
      if partial ~= "" then append(partial); partial = "" end
      if stderr_partial ~= "" then table.insert(stderr_chunks, stderr_partial) end
      if running[buf] then
        complete({ ok = false, error = table.concat(stderr_chunks, "\n"):gsub("%s+$", "") ~= ""
          and table.concat(stderr_chunks, "\n") or ("exit " .. result.code) })
      end
    end))
    if not ok then
      winbar.spinner_stop_if_idle()
      stream_flush[buf] = nil
      report_error(buf, tostring(started))
      close_stream(buf)
      return
    end
    handle = started
    servers[buf] = handle
    process = handle
  end

  running[buf] = process
  local payload = vim.json.encode({ provider = provider, model = model, messages = messages, tools = vim.b[buf].yap_tools }) .. "\n"
  local ok, err = pcall(function() process:write(payload) end)
  if not ok then
    process:kill(15)
  end
end

--- Stop and wipe every child session when its parent is unloaded.
local function close_subagents(parent)
  subagent_children[parent] = nil
  for _, child in ipairs(vim.api.nvim_list_bufs()) do
    if child ~= parent and vim.b[child].yap and vim.b[child].yap_subagent_parent == parent then
      -- Closing a child must not send a late result into a parent being
      -- closed; stop it before wiping its buffer.
      subagent_done[child] = nil
      M.stop(child)
      if vim.api.nvim_buf_is_valid(child) then
        vim.npcall(vim.api.nvim_buf_delete, child, { force = true })
      end
    end
  end
end

--- Kill the in-flight request for the current buffer.
function M.stop(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local child = subagent_children[buf]
  subagent_children[buf] = nil
  if child then M.stop(child) end
  local handle = running[buf]
  if handle then
    handle:kill(15) -- the exit callback closes the interrupted turn
    servers[buf] = nil
    running[buf] = nil
    winbar.spinner_stop_if_idle()
    drain_tail(buf)
    local l = live[buf]
    if l then live[buf] = nil; vim.npcall(os.remove, l.log) end
    local f = stream_flush[buf]
    if f then
      f()
      stream_flush[buf] = nil
    end
    repair_stream_tail(buf)
    close_stream(buf)
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end
end

-- ─── Buffers ───────────────────────────────────────────────────────────────

-- Keymaps and buffer options shared by new and reopened session buffers.
function M.show_keymaps(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local entries, seen = {}, {}
  local modes = { "n", "i", "x", "o" }
  local function collect(maps, mode)
    for _, map in ipairs(maps) do
      if map.desc and map.desc:match("^yap:") then
        local key = mode .. "\0" .. map.lhs .. "\0" .. map.desc
        if not seen[key] then
          seen[key] = true
          entries[#entries + 1] = {
            lhs = map.lhs,
            mode = mode,
            desc = map.desc:sub(6),
          }
        end
      end
    end
  end
  for _, mode in ipairs(modes) do
    collect(vim.api.nvim_buf_get_keymap(buf, mode), mode)
    collect(vim.api.nvim_get_keymap(mode), mode)
  end
  table.sort(entries, function(a, b)
    if a.lhs == b.lhs then
      return a.mode < b.mode
    end
    return a.lhs < b.lhs
  end)

  local lines = {
    "Yap shortcuts (current buffer)",
    "Search with /, n and N; close with q or <Esc>.",
    "",
  }
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = string.format("%-18s %-2s %s", entry.lhs, entry.mode, entry.desc)
  end

  local panel = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(panel, 0, -1, false, lines)
  vim.bo[panel].modifiable = false
  vim.bo[panel].bufhidden = "wipe"
  local widest = 0
  for _, line in ipairs(lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line))
  end
  local width = math.max(1, math.min(vim.o.columns - 4, math.max(40, math.min(90, widest))))
  local height = math.max(1, math.min(#lines, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(panel, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Yap shortcuts ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = panel, silent = true, desc = "Close Yap shortcuts" })
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = panel, silent = true, desc = "Close Yap shortcuts" })
  return panel, win
end

local function setup_buffer(buf)
  -- Mark the buffer as a yap conversation BEFORE the filetype triggers the
  -- LSP's FileType autocommand, so the LspAttach guard in M.setup can see it.
  -- A chat buffer is not code: markdown LSPs (semantic tokens, inlay hints)
  -- add per-redraw cost on a large session and buy nothing (R1).
  vim.b[buf].yap = true
  -- Opening a saved session (:edit) sets the filetype before setup_buffer
  -- runs, so a markdown client may already be attached; stop it.
  if vim.lsp and vim.lsp.get_clients then
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
      vim.npcall(client.stop, client)
    end
  end

  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide"
  -- Sessions are managed, not workspace files: unlisted so they never
  -- clutter :ls or buffer pickers (MiniPick.buffers etc.); reach them
  -- with :YapInstances.
  vim.bo[buf].buflisted = false

  -- Stop treesitter's syntax highlighter (not the parser) when the user
  -- opts out. touchup runs its own queries over the parser, which stays
  -- loaded either way. Deferred so the FileType autocommands that started
  -- the highlighter have run.
  if not M.config.syntax_highlight then
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local hl = vim.treesitter.highlighter and vim.treesitter.highlighter.active[buf]
      if hl and hl.destroy then
        hl:destroy()
      end
    end)
  end

  -- Diff hunks are meaningless on a chat transcript, and mini.diff's
  -- number-column rendering collides with 'relativenumber': the two
  -- re-render the gutter together on every redraw (a ~20x cost on long
  -- sessions — relativenumber alone is ~0.01ms, mini.diff alone ~0, but
  -- combined ~0.24ms). Disable mini.diff here so relativenumber stays
  -- cheap. The buffer-local minidiff_disable flag makes mini.diff's
  -- BufEnter auto-enable refuse to re-attach.
  local ok_md, MiniDiff = pcall(require, "mini.diff")
  if ok_md and MiniDiff then
    vim.b[buf].minidiff_disable = true
    MiniDiff.disable(buf)
  end

  local keys = M.config.keymaps
  local map = function(mode, lhs, rhs, desc)
    if lhs == "" then
      return
    end
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  map("n", keys.send, M.send, "yap: send")
  map("i", keys.send, function()
    vim.cmd.stopinsert()
    M.send()
  end, "yap: send")
  map("n", keys.stop, function()
    M.stop()
  end, "yap: stop in-flight request")
  map("n", keys.change_model, function()
    M.change_model()
  end, "yap: change model")
  map("n", keys.live, function()
    M.live()
  end, "yap: live tool output")
  map("n", keys.scratch, function()
    M.scratch_toggle()
  end, "yap: toggle scratch")
  map("n", keys.insert, function()
    M.insert()
  end, "yap: insert template or skill")
  map("i", keys.insert, function()
    vim.cmd.stopinsert()
    M.insert()
  end, "yap: insert template or skill")
  map("n", keys.insert_here, function()
    M.insert(nil, { at_cursor = true })
  end, "yap: insert template or skill at cursor")
  map("n", keys.help, function()
    M.show_keymaps(buf)
  end, "yap: show shortcuts")
  require("harness.fold").setup_buffer(buf, keys)
  require("harness.textobj").setup_buffer(buf, keys)

  -- Self-evaluating winbar: a pure function of buffer state, refreshed
  -- by Neovim on every redraw.
  vim.wo.winbar = "%!v:lua.require'harness'.winbar()"
end

--- Open a new yap chat buffer.
function M.new(opts)
  opts = opts or {}
  local win = vim.api.nvim_get_current_win()
  local previous = vim.api.nvim_win_get_buf(win)
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  if opts.system then vim.b[buf].yap_system = opts.system end
  if opts.role then vim.b[buf].yap_role = opts.role end
  if opts.tools then vim.b[buf].yap_tools = opts.tools end
  if opts.path then
    vim.b[buf].yap_path = opts.path
    vim.api.nvim_buf_set_name(buf, opts.path)
  end
  vim.b[buf].yap_provider = opts.provider or M.config.provider
  vim.b[buf].yap_model = opts.model or M.config.model
  vim.b[buf].yap_project_cwd = vim.fs.normalize(vim.fn.getcwd())

  local lines = { "# @system", "" }
  vim.list_extend(lines, vim.split(vim.b[buf].yap_system or system_prompt(), "\n", { plain = true }))
  if opts.skills_intro or M.config.skills_intro then
    local intro = require("harness.template").skills_intro_lines()
    if intro then
      vim.list_extend(lines, { "", "## Skills" })
      vim.list_extend(lines, intro)
    end
  end
  vim.list_extend(lines, { "", "# @user", "" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  sync_frontmatter(buf) -- prepend the session's model state (R1: it lives in the buffer)
  -- Create the session file up front so the buffer is file-backed from
  -- the start: `:file` names the session immediately, before the first
  -- reply. The LSP guard in setup_buffer keeps markdown clients off it
  -- regardless of the .md extension.
  require("harness.session").save(buf)
  -- The tail is a rendering of the audit log: create its live-view buffer
  -- now (empty — the audit log is written on the first event), before any
  -- :file rename or tool run.
  ensure_tail(buf)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })

  setup_buffer(buf)
  if opts.hidden then vim.api.nvim_win_set_buf(win, previous) end

  return buf
end

-- A child has an ordinary session file and its own backend. The parent tool
-- waits in Go; a reply line to its serve process releases that tool call.
-- The tools a subagent role may request; role files also use the aliases
-- below (grep/find/webfetch) which are mapped onto these canonical names.
local ALLOWED_TOOLS = { "ls", "read", "search", "glob", "fetch", "bash", "python", "curl", "git", "write", "edit", "websearch", "quickfix", "ssh", "jev" }

-- A role with no `tools:` header gets this read-only set: a subagent is one
-- prompt-injection hop removed from the user's attention, so it must opt into
-- write/bash/python/curl/ssh explicitly. Any role may still request the full
-- set (minus recursive `subagent`) via its `tools:` header.
local DEFAULT_SUBAGENT_TOOLS = { "ls", "read", "search", "glob", "fetch", "git", "websearch", "quickfix", "jev" }

start_subagent = function(parent, ev)
  local function reply(text)
    local process = servers[parent]
    if process then
      process:write(vim.json.encode({ type = "subagent_result", id = ev.id, result = text }) .. "\n")
    end
  end
  if type(ev.role) ~= "string" or not ev.role:match("^[%w_-]+$") or type(ev.task) ~= "string" then
    reply("error: invalid subagent request")
    return
  end
  local role_file = paths.expand(M.config.roles_dir) .. "/" .. ev.role .. ".md"
  local ok_lines, lines = pcall(vim.fn.readfile, role_file)
  if not ok_lines or #lines == 0 or lines[1] ~= "---" then
    reply("error: missing role " .. ev.role .. " (" .. role_file .. ")")
    return
  end
  local header, closing = {}, nil
  for i = 2, #lines do
    if lines[i] == "---" then closing = i; break end
    local key, value = lines[i]:match("^(%w+):%s*(.-)%s*$")
    if key then header[key] = value end
  end
  if not closing then reply("error: invalid role " .. role_file); return end
  local body = table.concat(vim.list_slice(lines, closing + 1), "\n")
  local provider, model = util.current_combo(parent)
  -- Pi roles commonly use bare model names; Yap cannot infer their provider.
  -- Only a provider/model pair overrides the known-working parent combo.
  if header.model and header.model ~= "" then
    local p, m = header.model:match("^([^/]+)/(.+)$")
    if p then provider, model = p, m end
  end
  local allowed = vim.deepcopy(DEFAULT_SUBAGENT_TOOLS)
  if header.tools and header.tools ~= "" then
    allowed = {}
    local aliases = { grep = "search", find = "glob", webfetch = "fetch" }
    local known = {}
    for _, name in ipairs(ALLOWED_TOOLS) do
      known[name] = true
    end
    for name in header.tools:gmatch("[^,%s]+") do
      name = aliases[name] or name
      if not known[name] then
        reply("error: role " .. ev.role .. " requires unsupported tool " .. name)
        return
      end
      allowed[#allowed + 1] = name
    end
  end
  local parent_path = vim.b[parent].yap_path
  local stem = parent_path:gsub("%.md$", "")
  local child_path
  repeat
    local random = vim.uv.random(3)
    child_path = stem .. "-" .. string.format("%02x%02x%02x", random:byte(1, 3)) .. ".md"
  until vim.fn.filereadable(child_path) == 0
  local ok, child = pcall(M.new, { path = child_path, system = body, role = ev.role, provider = provider, model = model, tools = allowed, hidden = true })
  if not ok then reply("error: cannot create subagent: " .. tostring(child)); return end
  document.append_text(child, ev.task)
  vim.b[child].yap_subagent_parent = parent
  vim.b[child].yap_subagent_task = ev.task
  require("harness.session").save(child)
  subagent_children[parent] = child
  record_subagent(parent, child_path)
  subagent_done[child] = function(success)
    subagent_children[parent] = nil
    local result = "error: " .. (errors[child] or "subagent stopped without a result")
    if success then
      -- Only final prose, not the child's tool history, belongs in the parent.
      local text, in_comment = {}, false
      for _, line in ipairs(vim.api.nvim_buf_get_lines(child, 0, -1, false)) do
        if line == "# @assistant" then text, in_comment = {}, false
        elseif line:match("^<!%-%- /yap:tool") then text = {}
        elseif line:match("^<!%-%- yap:") then in_comment = not line:match("%-%->$")
        elseif in_comment then
          if line == "-->" then in_comment = false end
        elseif line ~= "# @user" then text[#text + 1] = line end
      end
      result = table.concat(text, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      if result == "" then result = "error: subagent returned no final answer" end
    end
    reply("Session: [" .. child_path .. "](" .. child_path .. ")\n" .. result)
  end
  M.send(child)
end

--- Open a saved session file as a yap buffer.
--- Turn a session-file buffer into a managed yap buffer: unlisted,
--- keymapped, tail (audit rendering) attached, model combo resumed from
--- frontmatter. Shared by :YapSessions resume and by directly opening
--- a file under ~/.yap/sessions/.
local function adopt(buf, path)
  if vim.b[buf].yap then
    return buf
  end
  vim.b[buf].yap_path = path
  vim.b[buf].yap_project_cwd = paths.project_cwd(path)
  -- Resume the recorded combo; legacy files without frontmatter keep the
  -- config default. Nothing is injected on open — that would dirty the
  -- buffer the moment it is resumed.
  local e = frontmatter_end(buf)
  if e then
    local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
    if fm and fm.provider and fm.provider ~= "" and fm.model and fm.model ~= "" then
      vim.b[buf].yap_provider = fm.provider
      vim.b[buf].yap_model = fm.model
    end
    if fm and fm.tools then vim.b[buf].yap_tools = fm.tools end
    if fm and fm.role then vim.b[buf].yap_role = fm.role end
  end
  -- A reopened session that ended on `# @user` awaits the next reply;
  -- seed the overview hint so it counts before its first send here.
  winbar.seed_awaiting(buf)
  setup_buffer(buf)
  ensure_tail(buf) -- restore the live view from the audit log (create if missing)
  seed_session_usage(buf) -- durable all-time totals from the audit log
  return buf
end

--- Focus an already-loaded buffer: jump to an existing window, otherwise
--- show it in the current one (unlisted sessions have no other way back).
local function focus_buf(buf)
  local wins = vim.fn.win_findbuf(buf)
  if wins[1] then
    vim.api.nvim_set_current_win(wins[1])
  else
    vim.api.nvim_set_current_buf(buf)
  end
end

--- Open a saved session file as a yap buffer.
function M.open(path)
  local buf = vim.fn.bufnr(vim.fn.fnamemodify(path, ":p"))
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
    -- Reuse the in-memory buffer with its unsaved changes; `:edit` would
    -- refuse to discard them (E37).
    focus_buf(buf)
    return adopt(buf, path)
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return adopt(vim.api.nvim_get_current_buf(), path)
end

--- Change the provider/model combo for the current buffer.
--- With an argument: "provider/model". Without: pick from setup()'s
--- models list, or — when that isn't configured — from `yap models`,
--- which queries every provider in config.json (GET /models).
function M.change_model(combo)
  local buf = vim.api.nvim_get_current_buf()
  if not combo then
    local function pick(items)
      vim.ui.select(items, { prompt = "yap model" }, function(choice)
        if choice then
          M.change_model(choice)
        end
      end)
    end
    if M.config.models and #M.config.models > 0 then
      pick(M.config.models)
      return
    end
    if models_cache then
      pick(models_cache)
      return
    end
    table.insert(models_waiters, function(combos, stderr)
      if not combos then
        local err = (stderr or ""):gsub("%s+$", "")
        vim.notify("yap: no models found" .. (err ~= "" and (": " .. err) or ""), vim.log.levels.WARN)
      else
        pick(combos)
      end
    end)
    refresh_models()
    return
  end
  local provider, model = combo:match("^([%w_.:%-]+)/([%w_.:%-]+)$")
  if not provider then
    vim.notify("yap: expected provider/model, got: " .. combo, vim.log.levels.ERROR)
    return
  end
  vim.b[buf].yap_provider = provider
  vim.b[buf].yap_model = model
  sync_frontmatter(buf) -- persist: combo + used-models history live in the buffer
end

--- Pick a saved session and open it. scope: "cwd" (default) or "all".
function M.sessions(scope)
  require("harness.session").pick({ scope = scope }, function(path)
    M.open(path)
  end)
end

--- Session label for the picker: description when present, filename as
--- fallback, prefixed with the project cwd.
local function live_session_label(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local path = (name ~= "" and not name:match("^%a+://")) and name or (vim.b[buf].yap_path or name)
  local e = frontmatter_end(buf)
  local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false)) or nil
  local label = require("harness.session").label(path, fm and fm.description, vim.b[buf].yap_project_cwd)
  local parent = vim.b[buf].yap_subagent_parent
  if parent and vim.api.nvim_buf_is_valid(parent) and vim.b[parent].yap then
    local task = (vim.b[buf].yap_subagent_task or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if vim.fn.strdisplaywidth(task) > 72 then
      local chars = vim.fn.strchars(task)
      while chars > 1 and vim.fn.strdisplaywidth(vim.fn.strcharpart(task, 0, chars) .. "…") > 72 do
        chars = chars - 1
      end
      task = vim.fn.strcharpart(task, 0, chars) .. "…"
    end
    return "  ↳ " .. (fm.role or vim.b[buf].yap_role or "subagent") .. ": " .. task
  end
  if fm and fm.role then
    label = label .. "  [subagent: " .. fm.role .. "]"
  end
  return label
end

--- Plain state token for a buffer: the key |M.instances| filters on, and
--- the word behind each picker status glyph.
local function session_state(buf)
  if running and running[buf] then
    return "running"
  elseif errors[buf] then
    return "error"
  elseif awaiting[buf] then
    return "waiting"
  end
  return "idle"
end

--- Status word + glyph for the session picker, mirroring the winbar state
--- chips so both views agree. The picker is static, so a fixed glyph
--- stands in for the winbar's animated spinner.
local function session_status(buf)
  local ic = M.config.icons
  local glyph = { running = ic.running, error = ic.error, waiting = ic.waiting, idle = ic.idle }
  local state = session_state(buf)
  return glyph[state] .. " " .. state
end

--- Sort waiting sessions last; their dedicated :YapWaiting / <leader>w picker
--- makes them easy to reach without letting them crowd the general list.
local function session_rank(buf)
  if errors[buf] then
    return 1
  elseif running and running[buf] then
    return 2
  elseif awaiting[buf] then
    return 4
  end
  return 3
end

--- Every open yap chat buffer except the current one, annotated with its live
--- state and sorted with waiting sessions last. An optional `state`
--- ("running", "error", "waiting" or "idle") narrows the list; a current
--- parent remains visible while it has an open subagent. Tails are never here —
--- use :YapLive / <leader>l.
local function has_open_subagent(parent)
  local child = subagent_children[parent]
  if child and vim.api.nvim_buf_is_valid(child) then
    return true
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= parent and vim.b[buf].yap and vim.b[buf].yap_subagent_parent == parent then
      return true
    end
  end
  return false
end

function M.instances(state)
  local items = {}
  local current = vim.api.nvim_get_current_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local include_current_parent = b == current and has_open_subagent(b)
    if (b ~= current or include_current_parent) and vim.b[b].yap
      and not (state == "waiting" and vim.b[b].yap_subagent_parent)
      and (state == nil or session_state(b) == state) then
      items[#items + 1] = {
        buf = b,
        text = live_session_label(b),
        status = session_status(b),
        group_parent = (vim.b[b].yap_subagent_parent and vim.api.nvim_buf_is_valid(vim.b[b].yap_subagent_parent))
          and vim.b[b].yap_subagent_parent or b,
      }
    end
  end
  if #items == 0 then
    local message = "yap: no open sessions"
    if state == "waiting" then
      message = "yap: nothing waiting for a reply"
      if vim.b[current].yap and session_state(current) == "waiting" then
        message = "yap: current session is already open and waiting for a reply"
      end
    end
    vim.notify(message, vim.log.levels.INFO)
    return
  end
  table.sort(items, function(a, b)
    local ra, rb = session_rank(a.buf), session_rank(b.buf)
    if ra ~= rb then
      return ra < rb
    end
    if a.group_parent == b.group_parent and a.buf ~= b.buf then
      return a.buf == a.group_parent
    end
    return a.text < b.text
  end)
  local width = 0
  for _, item in ipairs(items) do
    width = math.max(width, vim.fn.strdisplaywidth(item.text))
  end
  vim.ui.select(items, {
    prompt = state == "waiting" and "yap waiting" or "yap sessions",
    format_item = function(item)
      return item.text .. string.rep(" ", width - vim.fn.strdisplaywidth(item.text) + 2) .. item.status
    end,
    preview_item = function(item)
      return require("harness.session").preview(vim.api.nvim_buf_get_lines(item.buf, 0, -1, false))
    end,
  }, function(choice)
    if choice then
      focus_buf(choice.buf)
    end
  end)
end

--- Just the sessions awaiting a reply — the "needs you" set (<leader>w).
function M.waiting()
  M.instances("waiting")
end

function M.setup(opts)
  opts = opts or {}
  if opts.nerd_font == false then
    M.config.icons = vim.tbl_extend("force", M.config.icons, {
      since = "", total = "", running = "▶", error = "✗", waiting = "◉",
      idle = "○", steer = "⌁", approval = "⚠", fold = "Ⓕ",
      cap_l = "[", cap_r = "]",
    })
  end
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  if not M.config.models or #M.config.models == 0 then
    local path = models_cache_path()
    if vim.fn.filereadable(path) == 1 then
      local cached = vim.fn.readfile(path)
      if #cached > 0 then models_cache = cached end
    end
    refresh_models()
  end
  -- Propagate the (possibly overridden) data roots to the path resolver.
  paths.dirs.sessions_dir = M.config.sessions_dir
  paths.dirs.audit_dir = M.config.audit_dir

  -- <leader>r and <leader>w are global: they list sessions across every
  -- buffer, so they must work from any file, not just inside a chat. The
  -- other keymaps act on the current buffer and stay buffer-local in
  -- setup_buffer.
  if M.config.keymaps.sessions ~= "" then
    vim.keymap.set("n", M.config.keymaps.sessions, function()
      M.instances()
    end, { silent = true, desc = "yap: sessions" })
  end
  if M.config.keymaps.waiting ~= "" then
    vim.keymap.set("n", M.config.keymaps.waiting, function()
      M.waiting()
    end, { silent = true, desc = "yap: waiting sessions" })
  end

  -- Opening a file under ~/.yap/sessions/ directly (e.g. from a file
  -- explorer) adopts it as a managed yap session. Session buffers stay
  -- out of :ls no matter how they got in: BufAdd fires whenever a buffer
  -- enters the buffer list (new buffers, :badd, :args/:next, and plugins
  -- that relist), so unlisting there is the single consistent guard. It
  -- does not fire during startup, so the BufReadPost adopt below and the
  -- lazy-setup scan after it own that path.
  local adopt_group = vim.api.nvim_create_augroup("YapAdopt", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = adopt_group,
    callback = function(args)
      local process = servers[args.buf]
      if process then process:kill(15) end
      servers[args.buf] = nil
      running[args.buf] = nil
      -- Release the per-buffer UI state so the winbar's rollup and cache
      -- don't iterate/retain entries for buffers that are gone.
      live[args.buf] = nil
      errors[args.buf] = nil
      last_turn[args.buf] = nil
      awaiting[args.buf] = nil
      description_seq[args.buf] = nil
      description_started[args.buf] = nil
      winbar.clear_desc(args.buf)
      fold.clear_text(args.buf)
      focus_forget(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = adopt_group,
    callback = function(args)
      local buf = args.buf
      if not vim.b[buf].yap then
        return
      end
      -- Let window/buffer transitions settle; focusing a drawer alone must
      -- not close it while the chat remains displayed in another window.
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
          close_session_drawers(buf)
        end
      end)
    end,
  })
  -- Record focus order so :bd/:bw/:close on a session can land on a
  -- waiting session, else the last file buffer (unlisted sessions are
  -- invisible to Neovim's own replacement-buffer search).
  vim.api.nvim_create_autocmd("BufEnter", {
    group = adopt_group,
    callback = function(args)
      focus_touch(args.buf)
    end,
  })
  -- harness.fold owns synchronous window-entry reconciliation; scheduling
  -- it here would expose an unfolded frame when a hidden stream is shown.
  -- Redirect :bd/:bw/:bdelete/:bunload of the current session buffer. The
  -- deletion itself fires BufUnload while curbuf is still the session; by
  -- the time a scheduled callback runs, Neovim has moved curbuf to another
  -- listed buffer or to the fresh empty buffer its "last listed buffer"
  -- path creates. Switch to the fallback and drop that empty buffer.
  vim.api.nvim_create_autocmd("BufUnload", {
    group = adopt_group,
    callback = function(args)
      local buf = args.buf
      if vim.b[buf].yap then
        close_subagents(buf)
        M.stop(buf)
      end
      if vim.api.nvim_get_current_buf() ~= buf or not vim.b[buf].yap then
        return
      end
      local target = focus_fallback(buf)
      if not target then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(target) then
          return
        end
        local cur = vim.api.nvim_get_current_buf()
        if cur == target then
          return
        end
        -- Drop the empty buffer :bd just created so no stray [No Name]
        -- lingers in :ls.
        if vim.api.nvim_buf_get_name(cur) == "" and not vim.bo[cur].modified then
          local lines = vim.api.nvim_buf_get_lines(cur, 0, -1, false)
          if #lines <= 1 and (#lines == 0 or lines[1] == "") then
            vim.api.nvim_set_current_buf(target)
            vim.npcall(vim.api.nvim_buf_delete, cur, { force = true })
            return
          end
        end
        vim.api.nvim_set_current_buf(target)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = adopt_group,
    callback = function()
      for _, process in pairs(servers) do process:kill(15) end
    end,
  })
  local function is_session_path(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    local root = paths.sessions_root()
    return name, name:sub(1, #root + 1) == root .. "/"
  end
  vim.api.nvim_create_autocmd("BufAdd", {
    group = adopt_group,
    callback = function(args)
      local _, session_path = is_session_path(args.buf)
      if session_path then
        vim.bo[args.buf].buflisted = false
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = adopt_group,
    callback = function(args)
      local name, session_path = is_session_path(args.buf)
      if session_path then
        adopt(args.buf, name)
      end
    end,
  })
  -- The winbar degrades with window width (see render_winbar); re-evaluate
  -- its `%!` expression whenever a window is resized.
  vim.api.nvim_create_autocmd("WinResized", {
    group = adopt_group,
    callback = function()
      vim.cmd.redrawstatus()
    end,
  })
  -- Session files loaded before setup() ran (lazy loading) missed both
  -- BufAdd and BufReadPost; unlist them once, when setup() finally runs.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local _, session_path = is_session_path(b)
    if session_path then
      vim.bo[b].buflisted = false
    end
  end

  -- yap buffers carry no language server: the buffer is the conversation
  -- (R1), and a markdown LSP streaming semantic-token/inlay-hint updates is
  -- pure per-redraw cost. The guard stops any client that attaches to a
  -- marked buffer; setup_buffer marks the buffer and stops clients that
  -- attached during :edit before the mark existed.
  local group = vim.api.nvim_create_augroup("YapLsp", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      if vim.b[args.buf].yap and args.data and args.data.client_id then
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client then
          vim.npcall(client.stop, client)
        end
      end
    end,
  })

  -- Turn completion is a first-class event: User YapTurnDone fires per
  -- buffer when a send finishes. The default handler is the herdr-style
  -- "it's waiting for you" toast, but any user autocmd can hook the
  -- same event — noice/nf-notify rendering, chaining a next send, etc.
  -- Announce only buffers the user isn't looking at.
  local notify_group = vim.api.nvim_create_augroup("YapTurn", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = notify_group,
    pattern = "YapTurnDone",
    callback = function(args)
      local data = args.data or {}
      if not M.config.notify_done then
        return
      end
      -- The error path already notified (R9); don't double up.
      if errors[data.buf] then
        return
      end
      -- The session is being closed by a tool call, so there is no waiting
      -- session to announce when this turn finishes.
      if close_after_turn[data.buf] then
        return
      end
      -- When the chat is current, the stream is right in front of you.
      if vim.api.nvim_get_current_buf() == data.buf then
        return
      end
      local t = data.turn or {}
      local msg = t.model and ("yap: %s done"):format(t.model) or "yap: turn done"
      if t.prompt or t.completion then
        msg = msg .. (" · %s in · %s out"):format(util.fmt_tokens(t.prompt or 0), util.fmt_tokens(t.completion or 0))
      end
      if t.cost then
        msg = msg .. (" · $%.4g"):format(t.cost)
      end
      if t.ms then
        msg = msg .. (" · %.1fs"):format(t.ms / 1000)
      end
      vim.notify(msg, vim.log.levels.INFO, { title = "yap" })
    end,
  })
end

return M
