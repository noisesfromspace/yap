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
  roles_dir = vim.fn.expand("~/.yap/roles"), -- subagent role definitions
  -- List available skills (name + description) in new chats' system block
  -- so they are discoverable; bodies are only ever inserted manually.
  skills_intro = true,
  -- vim.notify when a turn completes in a buffer that is not focused
  -- (see the User YapTurnDone autocmd installed by setup()).
  notify_done = true,
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
  -- `sessions` is the only global one (installed by setup()).
  keymaps = {
    send = "<C-s>",
    stop = "<leader>c",
    change_model = "<leader>m",
    live = "<leader>l",
    scratch = "<leader>s",
    insert = "<leader>t",
    insert_here = "<leader>T",
    sessions = "<leader>r",

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

-- Cached output of `yap models` ("provider/model" lines) so
-- <leader>m / :YapChangeModel doesn't re-query every provider on each
-- press — that's one GET /models per provider in config.json, sequential,
-- each with a 10s timeout. Refreshed by :YapReload (module state is
-- dropped); model lists rarely change between sessions.
local models_cache = nil

local frontmatter = require("harness.frontmatter")
local paths = require("harness.path")

-- The harness's own boilerplate, always injected as the first system
-- message on every send. It is independent of agents_file (the user's
-- rules) and lives here so session files never store it.
local function yap_about()
  return [[# About Yap

You are running inside Yap, an agent harness for Neovim. The conversation is an editable Markdown buffer and the source of truth: `# @system`, `# @user`, and `# @assistant` headings delimit messages; editing or deleting a message branches or rewrites history, and the visible transcript is what is re-sent. Never emit one of those headings or a `<!-- yap:` marker line in a reply — indent or fence it instead.

Between turns, tool calls and their results are plain text in the transcript, not re-executed or re-sent. When asked about Yap itself, read `README.md` / `doc/yap.txt` in the project (normally `/opt/code/yap`) rather than guessing.

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

--- The combo yap will send with: per-buffer vars (set by :Yap),
--- falling back to the global config.
local function current_combo(buf)
  return vim.b[buf].yap_provider or M.config.provider, vim.b[buf].yap_model or M.config.model
end

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
  local provider, model = current_combo(buf)
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
  local block = frontmatter.render(provider, model, models, created_at, fm and fm.description, fm and fm.role or vim.b[buf].yap_role, fm and fm.tools or vim.b[buf].yap_tools)
  if e then
    vim.api.nvim_buf_set_lines(buf, 0, e, false, block)
  else
    table.insert(block, "")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, block)
  end
end

-- ─── Winbar (busy indicator, provider/model) ──────────────────────────────

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_tick = 0
local spinner_timer = nil

-- Forward declarations: `running`, `live` and `drain_tail` are defined
-- with the send logic below.
local running
local live
local drain_tail
-- Defined with the description stages below; send() calls it.
local refresh_description
local start_subagent
local subagent_done = {}
local subagent_children = {}

-- The winbar is a statusline: `%` starts a format item there, so any
-- literal `%` in segment text (the context-fill chip, a session title that
-- contains a percent sign) must be doubled. This runs on the content only —
-- the `%#…#` / `%*` highlight markers these helpers add are not escaped.
local function esc(text)
  return text:gsub("%%", "%%%%")
end

local function winbar_hl(text, group)
  return "%#Yap" .. group .. "#" .. esc(text) .. "%*"
end

-- Island segments share one raised background (`YapIsland`); each chip
-- keeps its own foreground via `YapIsland<Group>`. `%*` resets to the
-- WinBar default, so every island piece re-applies its own highlight.
local function island_hl(text, group)
  return "%#YapIsland" .. (group or "") .. "#" .. esc(text) .. "%*"
end

-- Last backend error per buffer; shown in the winbar until the next send.
local stream = require("harness.stream")
local errors = stream.errors

-- The agent is awaiting the user's next prompt: set when a turn
-- completes (a `# @user` heading is appended), cleared when the user
-- sends. Drives the herdr-style "needs you" winbar state. A UI hint,
-- not conversation state (R1) — same drift tradeoff as yap_usage.
local awaiting = {}

-- Data of the last completed turn per buffer (the binary's `turn_end`
-- event), handed to the User YapTurnDone autocmd. Ephemeral.
local last_turn = stream.last_turn

-- Other yap buffers awaiting the user's reply: the count for the
-- global overview chip. A tiny module map, so no buffer scans on redraw
-- (R10); stale entries are skipped via the validity check.
local function awaiting_others(buf)
  local n = 0
  for b in pairs(awaiting) do
    if b ~= buf and vim.api.nvim_buf_is_valid(b) and vim.b[b].yap then
      n = n + 1
    end
  end
  return n
end

-- Other yap buffers with an in-flight request: the `▶N` running rollup,
-- mirroring awaiting_others so both chips skip the current buffer and
-- stale entries.
local function running_others(buf)
  local n = 0
  for b in pairs(running) do
    if b ~= buf and vim.api.nvim_buf_is_valid(b) and vim.b[b].yap then
      n = n + 1
    end
  end
  return n
end

-- Seed the awaiting hint for a reopened session from its content (R1):
-- it awaits the next reply when it has assistant history and ends on a
-- `# @user` heading. One-time scan at open, never on redraw.
local function seed_awaiting(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local has_asst = false
  for _, l in ipairs(lines) do
    if l == "# @assistant" then
      has_asst = true
      break
    end
  end
  if not has_asst then
    awaiting[buf] = nil
    return
  end
  awaiting[buf] = nil
  for i = #lines, 1, -1 do
    if lines[i] == "# @user" then
      awaiting[buf] = true
      return
    elseif lines[i] == "# @assistant" then
      return
    end
  end
end

local function fmt_tokens(n)
  local value, suffix
  if n >= 1000000 then
    value, suffix = n / 1000000, "m"
  elseif n >= 1000 then
    value, suffix = n / 1000, "k"
  else
    return tostring(n)
  end
  if value == math.floor(value) then
    return string.format("%d%s", value, suffix)
  end
  return string.format("%.1f%s", value, suffix)
end

--- The session description for the winbar. A bounded read of the short
--- frontmatter block, so hand edits show up on the next redraw (the buffer
--- stays the source of truth); truncate to `max` display columns so a long
--- phrase cannot crowd out the right-hand usage/state chips.
local function winbar_description(buf, max)
  max = max or 40
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 30, false)
  if not lines[1] or not lines[1]:match("^%-%-%-%s*$") then
    return nil
  end
  local fm = frontmatter.parse(lines)
  local d = fm and fm.description
  if not d or d == "" then
    return nil
  end
  if vim.fn.strdisplaywidth(d) > max then
    local chars = math.min(vim.fn.strchars(d), math.max(1, max - 1))
    d = vim.fn.strcharpart(d, 0, chars)
    while vim.fn.strdisplaywidth(d .. "…") > max and chars > 1 do
      chars = chars - 1
      d = vim.fn.strcharpart(d, 0, chars)
    end
    d = d .. "…"
  end
  return d
end

-- Layout: a busy beacon and a global-session island on the left, then the
-- current session's title/model/fold view; activity on the right — usage
-- totals first, then the state glyph pinned to the far right edge so it
-- never moves as numbers grow. The bar is width-aware: as the window
-- narrows it drops the state glyph first (busy is duplicated by the left
-- beacon), then the model/fold cluster, then collapses the token phrase
-- (in→out), and finally shrinks the description. The island and the two
-- prices are the last things standing.
local function render_winbar(buf)
  local provider, model = current_combo(buf)
  local ok_w, width = pcall(vim.api.nvim_win_get_width, 0)
  if not ok_w or not width or width <= 0 then
    width = 999 -- no window context: render the full bar
  end

  local function seg(text, group, island)
    return { text = text, group = group, island = island }
  end
  local function render_seg(s)
    if s.island then
      return island_hl(s.text, s.group)
    end
    return winbar_hl(s.text, s.group or "Idle")
  end
  local function width_of(segs)
    local n = 0
    for _, s in ipairs(segs) do
      n = n + vim.fn.strdisplaywidth(s.text)
    end
    return n
  end

  -- Mandatory left cluster (never dropped; the description shrinks).
  local function left_segments(desc_max)
    local left = {}
    if running and running[buf] then
      left[#left + 1] = seg(" ▶ ", "Busy")
    end
    local running_others_n = running_others(buf)
    local others = awaiting_others(buf)
    if running_others_n > 0 or others > 0 then
      left[#left + 1] = seg(" ", nil, true)
      if running_others_n > 0 then
        left[#left + 1] = seg("▶" .. running_others_n, "Busy", true)
      end
      if running_others_n > 0 and others > 0 then
        left[#left + 1] = seg(" │ ", nil, true)
      end
      if others > 0 then
        left[#left + 1] = seg("◉" .. others, "Needs", true)
      end
      left[#left + 1] = seg(" ", nil, true)
    end
    local desc = winbar_description(buf, desc_max)
    if desc then
      left[#left + 1] = seg(" " .. desc, "Description")
      left[#left + 1] = seg(" · ", "Idle")
    end
    return left
  end

  -- Droppable middle: provider/model and the applied fold view.
  local function mid_segments()
    return {
      seg(provider .. "/" .. model, "Model"),
      seg(" · Ⓕ" .. require("harness.fold").level() .. " ", "Idle"),
    }
  end

  -- Usage/cost cluster. mode: "full" (tokens + both prices), "compact"
  -- (in→out tokens + both prices), "prices" (both prices only). The first
  -- $ is this buffer's accumulated cost; Σ is the all-time session cost
  -- from the audit log. Returns a list of segments so the context-fill
  -- chip can carry its own highlight.
  local function usage_segment(mode)
    local items = {} -- { text, group }
    local u = vim.b[buf].yap_usage
    local s = vim.b[buf].yap_session_usage
    if u and (u.prompt > 0 or u.completion > 0) and mode ~= "prices" then
      if mode == "full" then
        items[#items + 1] = { fmt_tokens(u.prompt) .. " in · " .. fmt_tokens(u.completion) .. " out", "Idle" }
      else
        items[#items + 1] = { fmt_tokens(u.prompt) .. "→" .. fmt_tokens(u.completion), "Idle" }
      end
    end
    -- Context fill: the last turn's prompt tokens against the model's
    -- context window (both carried by the turn_end event). A near-full
    -- window is a safety signal, so it gets the warning color.
    local t = last_turn[buf]
    local ctx = t and tonumber(t.context_window) or nil
    if ctx and ctx > 0 and t.prompt and t.prompt > 0 then
      local pct = math.floor(t.prompt / ctx * 100 + 0.5)
      items[#items + 1] = { pct .. "% ctx", pct >= 90 and "Needs" or "Idle" }
    end
    if u and u.cost then
      items[#items + 1] = { string.format("$%.4g", u.cost), "Idle" }
    end
    if s and s.cost then
      items[#items + 1] = { (mode == "full" and "session " or "Σ") .. string.format("$%.4g", s.cost), "Idle" }
    end
    if #items == 0 then
      return nil
    end
    local segs = { seg(" " .. items[1][1], items[1][2]) }
    for i = 2, #items do
      segs[#segs + 1] = seg(" · " .. items[i][1], items[i][2])
    end
    segs[#segs].text = segs[#segs].text .. " "
    return segs
  end

  local function state_segment()
    if running and running[buf] then
      local frame = SPINNER[(spinner_tick % #SPINNER) + 1]
      local l = live and live[buf]
      local state = l and (frame .. " " .. l.name .. " " .. (os.time() - l.since) .. "s") or (frame .. " busy")
      return seg(" " .. state .. " ", "Busy")
    elseif errors[buf] then
      return seg(" ✗ error ", "Error")
    elseif awaiting[buf] then
      return seg(" ◉ waiting ", "Needs")
    else
      return seg(" ○ idle ", "Idle")
    end
  end

  local function render(left, mid, usage, state)
    local parts = {}
    for _, s in ipairs(left) do
      parts[#parts + 1] = render_seg(s)
    end
    for _, s in ipairs(mid) do
      parts[#parts + 1] = render_seg(s)
    end
    parts[#parts + 1] = "%="
    if usage then
      for _, s in ipairs(usage) do
        parts[#parts + 1] = render_seg(s)
      end
    end
    if state then
      parts[#parts + 1] = render_seg(state)
    end
    return table.concat(parts, "")
  end

  -- Degrade until the bar fits, dropping the least important parts first:
  -- state glyph → model/fold → token phrase → description. Prices and the
  -- island survive; past that the bar clips rather than hiding prices.
  local desc_max, mode, show_mid, show_state = 40, "full", true, true
  while true do
    local left = left_segments(desc_max)
    local mid = show_mid and mid_segments() or {}
    local usage = usage_segment(mode)
    local state = show_state and state_segment() or nil
    local total = width_of(left) + width_of(mid)
      + (usage and width_of(usage) or 0)
      + (state and width_of({ state }) or 0)
    if total <= width then
      return render(left, mid, usage, state)
    end
    if show_state then
      show_state = false
    elseif show_mid then
      show_mid = false
    elseif mode == "full" then
      mode = "compact"
    elseif mode == "compact" then
      mode = "prices"
    elseif desc_max > 15 then
      desc_max = desc_max - 5
    else
      return render(left, mid, usage, state) -- smallest layout; let it clip
    end
  end
end

--- Winbar expression: the winbar is set to a self-evaluating `%!` call of
--- this function, so it always reflects current buffer state on redraw —
--- no imperative refresh calls anywhere.
function M.winbar(buf)
  buf = buf or tonumber(vim.g.actual_curbuf) or vim.api.nvim_get_current_buf()
  return render_winbar(buf)
end

--- The herdr-style rollup for a statusline/tabline: `◉N` when N OTHER
--- yap buffers await the user's reply, "" otherwise. The winbar shows
--- the same chip, so this is the reusable segment for global visibility.
function M.overview(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local n = awaiting_others(buf)
  return n > 0 and ("◉" .. n) or ""
end

local function spinner_stop_if_idle()
  if spinner_timer and not next(running) then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
end

local function spinner_start()
  if spinner_timer then
    return
  end
  spinner_timer = vim.uv.new_timer()
  spinner_timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      spinner_tick = spinner_tick + 1
      for b in pairs(running) do
        drain_tail(b) -- pull new tool output into the tail buffers
      end
      vim.cmd.redrawstatus() -- re-evaluates the winbar expression
      spinner_stop_if_idle()
    end)
  )
end

local function define_winbar_hl()
  local links = {
    Model = "Keyword",
    Description = "Title",
    Busy = "DiagnosticOk",
    Idle = "Comment",
    Error = "DiagnosticError",
    Needs = "DiagnosticWarn",
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, "Yap" .. name, { default = true, link = link })
  end

  -- The island is a raised pill: a theme-aware background (NormalFloat,
  -- falling back to Visual) with the chip foregrounds pulled from the
  -- linked groups above so user `:hi YapBusy` overrides still win.
  local function attr(group, key)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and hl and hl[key] then
      return hl[key]
    end
  end
  local bg = attr("NormalFloat", "bg") or attr("Visual", "bg")
  local fg = attr("WinBar", "fg") or attr("StatusLine", "fg")
  vim.api.nvim_set_hl(0, "YapIsland", { default = true, fg = fg, bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandBusy", { default = true, fg = attr("YapBusy", "fg"), bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandNeeds", { default = true, fg = attr("YapNeeds", "fg"), bg = bg })
end

define_winbar_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("YapWinbarHl", { clear = true }),
  callback = define_winbar_hl,
})

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
  return stream.is_running(buf)
end

-- ─── Send ──────────────────────────────────────────────────────────────────

-- In-flight jobs per buffer (vim.SystemObj can't live in vim.b).
running = stream.running

-- One persistent serve backend per chat buffer, so several sessions can
-- stream at once. Each backend keeps its own tool state (SSH connections
-- above all) for the life of its buffer; a stopped process is restarted
-- on the next send.
local servers = {} -- buf → vim.SystemObj

-- Live tool per buffer while it runs: { name, log, since }. Set from
-- the binary's `yap:event` stderr lines (bash announces the temp file
-- its output streams into), cleared on tool_end / process exit.
live = stream.live

-- Per-chat-buffer persistent tail: every audit event is rendered into
-- ONE unlisted buffer, yap://<session>-tail, opened by :YapLive. The
-- tail is not a second log — it is the live, human-readable rendering
-- of the JSON Lines audit log (see audit_path), rebuilt from it on
-- reopen. Only the audit log is persisted.
local tails = {} -- chat buf → { bufnr, offset, has_content, audit }

-- The audit dir holds one JSON Lines audit log per session, keyed by
-- the session's basename, so the sessions dir stays clean.

--- The tail buffer's name; mirrors the session file's basename so
--- `:file` renames keep the two together.

--- Append one event as a JSON object to the session's audit log.
local function audit_append(buf, ev)
  local t = tails[buf]
  if not t then
    return
  end
  if not t.audit then
    t.audit = paths.audit_path(buf)
    vim.fn.mkdir(vim.fn.fnamemodify(t.audit, ":h"), "p")
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
    vim.fn.mkdir(vim.fn.fnamemodify(want, ":h"), "p")
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

--- Append newly written bytes of the running tool's log to the tail
--- buffer (called on the spinner tick, on tool_end, and on process
--- exit). Defined via the forward declaration: the spinner ticks
--- before this section runs.
drain_tail = function(buf)
  local t, l = tails[buf], live[buf]
  if not t or not l then
    return
  end
  local fd = vim.uv.fs_open(l.log, "r", 438)
  if not fd then
    return
  end
  local stat = vim.uv.fs_fstat(fd)
  local data = stat and stat.size > t.offset and vim.uv.fs_read(fd, stat.size - t.offset, t.offset) or nil
  if stat then
    t.offset = stat.size
  end
  vim.uv.fs_close(fd)
  if not data then
    return
  end
  append_event(buf, { type = "output", name = l.name, ts = os.date("%Y-%m-%dT%H:%M:%S"), data = data })
end

--- Handle one `yap:event {json}` line from the binary's stderr.
local function handle_event(buf, json_line)
  local ok, ev = pcall(vim.json.decode, json_line)
  if not ok or type(ev) ~= "table" then
    return
  end
  ev.ts = os.date("%Y-%m-%dT%H:%M:%S")
  if ev.type == "tool_start" and ev.log then
    live[buf] = { name = ev.name or "tool", log = ev.log, since = os.time() }
    local t = ensure_tail(buf)
    t.offset = 0
    append_event(buf, ev)
  elseif ev.type == "tool_end" then
    drain_tail(buf) -- the log is complete; capture the final bytes
    live[buf] = nil
    -- Go keeps the log for us; once drained, an untruncated one is gone
    -- (a truncated log stays: its result references it).
    if ev.log and not ev.truncated then
      pcall(os.remove, ev.log)
    end
  elseif ev.type == "subagent_request" then
    start_subagent(buf, ev)
  elseif ev.type == "subagent_timeout" then
    local child = subagent_children[buf]
    if child then M.stop(child) end
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
    end
    append_event(buf, ev) -- full arguments for every tool (bash renders via tool_start)
  elseif ev.type == "tool_result" then
    append_event(buf, ev) -- full result; bash output already streamed above
  elseif ev.type == "retry" then
    append_event(buf, ev) -- a transient generation error was retried
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
  vim.notify(
    ("yap: cleared %d tool result%s (kept the last %d)"):format(cleared, cleared == 1 and "" or "s", keep),
    vim.log.levels.INFO
  )
end

--- The compaction prompt: a `compact` template in templates_dir overrides
--- the built-in default (compaction is the template mechanism applied,
--- R18). Returns trimmed body lines, never a leading # @role heading.
local function compact_prompt_lines()
  local lines = require("harness.template").named_lines("compact")
  if lines then
    return lines
  end
  return vim.split(
    "Summarize the conversation above into a compact markdown summary that\n"
      .. "preserves all facts, decisions, open todos, and current file state.\n"
      .. "I will use that summary to continue the conversation with full context.",
    "\n",
    { plain = true }
  )
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
  vim.notify("yap: compacted — summary kept, history deleted", vim.log.levels.INFO)
end

--- Open the session's tail buffer (:YapLive): one persistent rendering
--- of the audit log, not a new terminal per call. Opens even before any
--- tool has run (an empty tail that fills as tools execute).
function M.live(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  for chat, t in pairs(tails) do
    if t.bufnr == buf then
      local wins = vim.fn.win_findbuf(buf)
      if #wins > 0 then
        vim.api.nvim_win_close(wins[1], false)
      end
      return
    end
  end
  local t = ensure_tail(buf)
  local wins = vim.fn.win_findbuf(t.bufnr)
  if #wins > 0 then
    vim.api.nvim_win_close(wins[1], false)
    return
  end
  vim.cmd("botright 12split")
  vim.api.nvim_win_set_buf(0, t.bufnr)
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

--- Take the text to send from the scratch buffer and remove it from the
--- queue: the active visual selection, or the whole buffer in normal mode.
--- The queue is a jotter, so <send> drains it — sent lines leave the buffer.
local function scratch_take(scratch)
  local mode = vim.api.nvim_get_mode().mode
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    local lines = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {})
    return lines
  end
  local anchor, cursor = vim.fn.getpos("v"), vim.fn.getpos(".")
  local text = vim.fn.getregion(anchor, cursor, { type = mode })
  if mode == "V" then
    -- Line-wise: drop the whole selected lines (no leftover empties).
    local from, to = math.min(anchor[2], cursor[2]), math.max(anchor[2], cursor[2])
    vim.api.nvim_buf_set_lines(scratch, from - 1, to, false, {})
  else
    -- Char/block-wise: remove exactly the selected byte ranges. getregionpos
    -- returns one [start, end] segment per line with inclusive end columns,
    -- so the exclusive API end column is the 1-based column unchanged.
    local ok, segs = pcall(vim.fn.getregionpos, anchor, cursor, { type = mode })
    if ok and type(segs) == "table" then
      for i = #segs, 1, -1 do
        local s, e = segs[i][1], segs[i][2]
        vim.api.nvim_buf_set_text(scratch, s[2] - 1, s[3] - 1, e[2] - 1, e[3], {})
      end
    end
  end
  -- The selection is consumed; drop back to normal mode so a stale visual
  -- selection can't eat the next keystroke.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, true, true), "x", false)
  return text
end

--- Write the queue buffer to its sibling file so the drained state survives
--- reopening the session. Like session.save it goes through `:write!` so the
--- buffer keeps owning the file (mtime/'modified' bookkeeping stay correct).
local function scratch_save(scratch)
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

--- Send the scratch queue — all of it, or the visual selection — into the
--- owning chat buffer as a `# @user` message, then submit it. The sent text
--- is removed from the queue by scratch_take, and the drained queue is saved
--- so already-sent tasks don't come back when the buffer is recreated.
function M.scratch_send(scratch)
  scratch = scratch or vim.api.nvim_get_current_buf()
  local owner = vim.b[scratch].yap_owner
  if not (owner and vim.api.nvim_buf_is_valid(owner)) then
    vim.notify("yap: scratch has no chat buffer", vim.log.levels.WARN)
    return
  end
  if M.is_running(owner) then
    vim.notify("yap: send in flight, not queueing", vim.log.levels.WARN)
    return
  end
  local text = scratch_take(scratch)
  local blank = true
  for _, l in ipairs(text) do
    if l:match("%S") then
      blank = false
      break
    end
  end
  if blank then
    vim.notify("yap: scratch is empty", vim.log.levels.WARN)
    return
  end
  document.append_message(owner, "user", text)
  scratch_save(scratch) -- persist the drain before the turn streams
  M.send(owner)
end

--- Toggle the session's scratch buffer (<leader>s): a fixed-height jotter
--- opened above the chat window. It is a real, file-backed buffer — a
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
    vim.bo[scratch].bufhidden = "hide"
    vim.bo[scratch].buflisted = false
    vim.b[buf].yap_scratch = scratch
    vim.b[scratch].yap_owner = buf
    if M.config.keymaps.scratch ~= "" then
      vim.keymap.set("n", M.config.keymaps.scratch, function()
        vim.api.nvim_win_close(0, false)
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

  -- Toggle: if the queue is already on screen, close it instead of opening
  -- a second window onto the same buffer (leftover reuse was doing that).
  local wins = vim.fn.win_findbuf(scratch)
  if #wins > 0 then
    for _, win in ipairs(wins) do
      vim.api.nvim_win_close(win, false)
    end
    return
  end

  vim.cmd("aboveleft " .. SCRATCH_HEIGHT .. "split")
  vim.api.nvim_win_set_buf(0, scratch)
  vim.wo.winfixheight = true
  vim.wo.winbar = "" -- a plain jotter, not a yap dashboard
  -- The split inherited the chat window's expr folds; a queue is a plain
  -- jotter, so drop foldexpr/foldtext evaluation (arbitrary queued text
  -- must never be interpreted as yap fold structure).
  vim.wo.foldmethod = "manual"
  vim.wo.foldexpr = ""
  vim.wo.foldtext = ""
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
  fold.after_append(buf, block)
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

--- Generate or refresh the session description shown in the winbar and
--- session picker. `kind` selects the model and what it summarizes:
---   "user"   — smallest model, the latest user message only (runs on send)
---   "answer" — bigger model, the whole session as a final title (runs once
---              the turn is back on the user block)
refresh_description = function(buf, kind, messages)
  local combo, system, content
  if kind == "user" then
    combo = M.config.description_model
    system = [[Write a short title for the user's request below.

Rules:
- 2-5 words, a specific noun phrase, not a sentence
- No leading "The user", no "how to", no trailing period
- Example: "Add websearch tool", "Fix fold lag on streaming"

Return only the title.]]
    for i = #messages, 1, -1 do
      if messages[i].role == "user" then
        content = messages[i].content
        break
      end
    end
    if not content or content == "" then
      return
    end
  else
    combo = M.config.description_answer_model
    system = [[Write a short session title centered on the overall goal, one that makes this conversation easy to find later.

Rules:
- 2-6 words, a specific noun phrase, not a sentence, no trailing period
- No "session", "conversation", "the user", "about"
- Prefer "Subject: change" so titles stay distinct across sessions in the same project
- Lead with the goal; only add the latest topic if the goal moved
- Example: "Fold lag: cache per changedtick"

Return only the title.]]
    content = vim.json.encode(document.parse_buffer(buf))
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
      if description == "" then
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
      local block = frontmatter.render(fm.provider, fm.model, fm.models, fm.created_at, description, fm.role, fm.tools)
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
  fold.after_append(buf, { "# @user", "" })
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
  local provider, model = current_combo(buf)
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
  -- Mark that a reply has streamed here: the folder keeps the latest
  -- assistant block open in view 1 so the reply is visible as it arrives
  -- (R10: the new assistant block opens by itself); older replies fold.
  -- Set before the append so the after_append fold re-apply already sees
  -- this block as live (level 1) rather than folding it once in view 1.
  vim.b[buf].yap_live = true
  document.append_block(buf, { "# @assistant", "" })
  fold.after_append(buf, { "# @assistant", "" })
  follow_tail()
  -- Sends never touch fold state or rewrite existing lines: the buffer
  -- is always in its final format, streaming only appends at the end,
  -- and new folds adopt the view's 'foldlevel' as they appear (R10) —
  -- the new assistant block opens by itself in every view.
  spinner_start()

  local process = servers[buf]
  if not process then
    local partial = ""
    local stderr_partial = ""
    local stderr_chunks = {}
    local status, barrier
    local function append(data)
      if data == "" then return end
      sync_followers()
      document.append_text(buf, data)
      fold.after_append(buf, vim.split(data, "\n", { plain = true }))
      follow_tail()
    end
    local function route_event(ev)
      sync_followers()
      handle_event(buf, ev)
      follow_tail()
    end
    local function complete(result)
      status, barrier = nil, false
      sync_followers()
      running[buf] = nil
      stderr_chunks = {}
      local compact = vim.b[buf].yap_compact_pending
      vim.b[buf].yap_compact_pending = nil
      local l = live[buf]
      drain_tail(buf) -- final bytes; a killed tool never sent tool_end
      if l then
        live[buf] = nil
        pcall(os.remove, l.log) -- a killed tool leaves a temp log behind
      end
      spinner_stop_if_idle()
      repair_stream_tail(buf)
      if not result.ok then
        local err = result.error or table.concat(stderr_chunks, "\n"):gsub("%s+$", "")
        report_error(buf, err ~= "" and err or "backend exited")
        close_stream(buf)
        follow_tail()
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
      document.append_block(buf, { "# @user", "" })
      fold.after_append(buf, { "# @user", "" })
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
      spinner_stop_if_idle()
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
    spinner_stop_if_idle()
    drain_tail(buf)
    local l = live[buf]
    if l then live[buf] = nil; pcall(os.remove, l.log) end
    repair_stream_tail(buf)
    close_stream(buf)
  end
end

-- ─── Buffers ───────────────────────────────────────────────────────────────

-- Keymaps and buffer options shared by new and reopened session buffers.
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
      pcall(client.stop, client)
    end
  end

  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide"
  -- Sessions are managed, not workspace files: unlisted so they never
  -- clutter :ls or buffer pickers (MiniPick.buffers etc.); reach them
  -- with :YapInstances.
  vim.bo[buf].buflisted = false

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
  map("n", keys.insert_here, function()
    M.insert(nil, { at_cursor = true })
  end, "yap: insert template or skill at cursor")
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
  local role_file = vim.fn.expand(M.config.roles_dir) .. "/" .. ev.role .. ".md"
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
  local provider, model = current_combo(parent)
  -- Pi roles commonly use bare model names; Yap cannot infer their provider.
  -- Only a provider/model pair overrides the known-working parent combo.
  if header.model and header.model ~= "" then
    local p, m = header.model:match("^([^/]+)/(.+)$")
    if p then provider, model = p, m end
  end
  local allowed = { "ls", "read", "search", "glob", "fetch", "bash", "python", "curl", "git", "write", "edit", "websearch", "quickfix", "ssh", "jev" }
  if header.tools and header.tools ~= "" then
    allowed = {}
    local aliases = { grep = "search", find = "glob", webfetch = "fetch" }
    local known = {}
    for _, name in ipairs({ "ls", "read", "search", "glob", "fetch", "bash", "python", "curl", "git", "write", "edit", "websearch", "quickfix", "ssh", "jev" }) do
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
  require("harness.session").save(child)
  subagent_children[parent] = child
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
  seed_awaiting(buf)
  setup_buffer(buf)
  ensure_tail(buf) -- restore the live view from the audit log (create if missing)
  seed_session_usage(buf) -- durable all-time totals from the audit log
  return buf
end

--- Open a saved session file as a yap buffer.
function M.open(path)
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
    vim.system({ M.config.bin, "models" }, { text = true }, function(res)
      vim.schedule(function()
        local combos = {}
        for line in (res.stdout or ""):gmatch("[^\n]+") do
          table.insert(combos, line)
        end
        if #combos == 0 then
          local err = (res.stderr or ""):gsub("%s+$", "")
          vim.notify("yap: no models found" .. (err ~= "" and (": " .. err) or ""), vim.log.levels.WARN)
          return
        end
        models_cache = combos
        pick(combos)
      end)
    end)
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
  vim.notify("yap: " .. provider .. "/" .. model)
end

--- Pick a saved session and open it. scope: "cwd" (default) or "all".
function M.sessions(scope)
  require("harness.session").pick({ scope = scope }, function(path)
    M.open(path)
  end)
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

--- Session label for the picker: description when present, filename as
--- fallback, prefixed with the project cwd.
local function live_session_label(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local path = (name ~= "" and not name:match("^%a+://")) and name or (vim.b[buf].yap_path or name)
  local e = frontmatter_end(buf)
  local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false)) or nil
  local label = require("harness.session").label(path, fm and fm.description, vim.b[buf].yap_project_cwd)
  if fm and fm.role then
    label = label .. "  [subagent: " .. fm.role .. "]"
  end
  return label
end

--- Status word + glyph for the session picker, mirroring the winbar state
--- chips so both views agree. The picker is static, so a filled circle
--- stands in for the winbar's animated spinner.
local function session_status(buf)
  if running and running[buf] then
    return "▶ running"
  elseif errors[buf] then
    return "✗ error"
  elseif awaiting[buf] then
    return "◉ waiting"
  end
  return "○ idle"
end

--- Sort needing-attention sessions first (error > waiting > busy > idle) so
--- the unified picker keeps the old "what needs me" role.
local function session_rank(buf)
  if errors[buf] then
    return 1
  elseif awaiting[buf] then
    return 2
  elseif running and running[buf] then
    return 3
  end
  return 4
end

--- Every open yap chat buffer, annotated with its live state and sorted so
--- sessions needing attention lead. Replaces the old <leader>w / <leader>r
--- split (tails are never here — use :YapLive / <leader>l).
function M.instances()
  local items = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].yap then
      items[#items + 1] = {
        buf = b,
        text = live_session_label(b),
        status = session_status(b),
      }
    end
  end
  if #items == 0 then
    vim.notify("yap: no open sessions", vim.log.levels.INFO)
    return
  end
  table.sort(items, function(a, b)
    local ra, rb = session_rank(a.buf), session_rank(b.buf)
    if ra ~= rb then
      return ra < rb
    end
    return a.text < b.text
  end)
  local width = 0
  for _, item in ipairs(items) do
    width = math.max(width, vim.fn.strdisplaywidth(item.text))
  end
  vim.ui.select(items, {
    prompt = "yap sessions",
    format_item = function(item)
      return item.text .. string.rep(" ", width - vim.fn.strdisplaywidth(item.text) + 2) .. item.status
    end,
    preview_item = function(item)
      return require("harness.session").preview_lines(vim.api.nvim_buf_get_lines(item.buf, 0, -1, false))
    end,
  }, function(choice)
    if choice then
      focus_buf(choice.buf)
    end
  end)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- <leader>r is global: it lists sessions across every buffer, so it
  -- must work from any file, not just inside a chat. The other keymaps
  -- act on the current buffer and stay buffer-local in setup_buffer.
  if M.config.keymaps.sessions ~= "" then
    vim.keymap.set("n", M.config.keymaps.sessions, function()
      M.instances()
    end, { silent = true, desc = "yap: sessions" })
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
          pcall(client.stop, client)
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
      -- When the chat is current, the stream is right in front of you.
      if vim.api.nvim_get_current_buf() == data.buf then
        return
      end
      local t = data.turn or {}
      local msg = t.model and ("yap: %s done"):format(t.model) or "yap: turn done"
      if t.prompt or t.completion then
        msg = msg .. (" · %s in · %s out"):format(fmt_tokens(t.prompt or 0), fmt_tokens(t.completion or 0))
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
