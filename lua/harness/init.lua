-- pitel.nvim — the buffer is the conversation.
--
-- A pitel buffer is plain markdown. Headings of the form `# @user`,
-- `# @assistant` and `# @system` delimit messages; everything between
-- headings is message content. The buffer is the ONLY state: deleting a
-- block removes it from the conversation, editing an assistant reply
-- changes what the model "said", inserting a fake reply steers it.
-- gptel semantics, Neovim native.
--
-- Sending serializes the whole buffer to the `pitel` binary, which talks
-- to the provider and streams the reply back into the buffer.

local M = {}

M.config = {
  bin = "pitel", -- path to the pitel binary
  provider = "moonshot",
  model = "kimi-k3",
  -- Optional override list of "provider/model" combos for
  -- :PitelChangeModel. When unset, the picker queries every provider
  -- in config.json for its model list (GET /models).
  models = nil,
  -- System prompt for new buffers: read from agents_file if it exists
  -- (pi-style ~/.config/pitel/AGENTS.md), otherwise this fallback.
  system = "You are a helpful coding assistant. Answer concisely.",
  agents_file = (vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. "/.config")) .. "/pitel/AGENTS.md",
  -- Templates are text files inserted into the context by :PitelInsert
  -- (a compaction prompt, a snippet, ...); skills are the same but
  -- system-prompt material, merged into the # @system block.
  templates_dir = (vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. "/.config")) .. "/pitel/templates",
  skills_dir = (vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. "/.config")) .. "/pitel/skills",
  -- List available skills (name + description) in new chats' system block
  -- so they are discoverable; bodies are only ever inserted manually.
  skills_intro = true,
}

-- Cached output of `pitel models` ("provider/model" lines) so
-- <leader>m / :PitelChangeModel doesn't re-query every provider on each
-- press — that's one GET /models per provider in config.json, sequential,
-- each with a 10s timeout. Refreshed by :PitelReload (module state is
-- dropped); model lists rarely change between sessions.
local models_cache = nil

local frontmatter = require("harness.frontmatter")

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

local roles = { system = "system", user = "user", assistant = "assistant" }

--- The combo pitel will send with: per-buffer vars (set by :Pitel),
--- falling back to the global config.
local function current_combo(buf)
  return vim.b[buf].pitel_provider or M.config.provider, vim.b[buf].pitel_model or M.config.model
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
  local block = frontmatter.render(provider, model, models)
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

local function winbar_hl(text, group)
  return "%#Pitel" .. group .. "#" .. text .. "%*"
end

-- Last backend error per buffer; shown in the winbar until the next send.
local errors = {}

local function fmt_tokens(n)
  if n >= 1000 then
    return string.format("%.1fk", n / 1000)
  end
  return tostring(n)
end

-- Layout: identity on the left (which model am I talking to), activity
-- on the right — usage totals first, then the state glyph pinned to the
-- far right edge so it never moves as numbers grow.
local function render_winbar(buf)
  local provider, model = current_combo(buf)
  local parts = {
    winbar_hl(" " .. provider .. "/" .. model .. " ", "Model"),
    winbar_hl(" Ⓕ" .. require("harness.fold").level() .. " ", "Idle"),
    "%=",
  }
  local u = vim.b[buf].pitel_usage
  if u and (u.prompt > 0 or u.completion > 0) then
    local usage = fmt_tokens(u.prompt) .. " in · " .. fmt_tokens(u.completion) .. " out"
    if u.cost then
      usage = usage .. " · " .. string.format("$%.4g", u.cost)
    end
    table.insert(parts, winbar_hl(" " .. usage .. " ", "Idle"))
  end
  if running and running[buf] then
    local frame = SPINNER[(spinner_tick % #SPINNER) + 1]
    local l = live and live[buf]
    local state = l and (frame .. " " .. l.name .. " " .. (os.time() - l.since) .. "s") or (frame .. " busy")
    table.insert(parts, winbar_hl(" " .. state .. " ", "Busy"))
  elseif errors[buf] then
    table.insert(parts, winbar_hl(" ✗ error ", "Error"))
  else
    table.insert(parts, winbar_hl(" ○ idle ", "Idle"))
  end
  return table.concat(parts, "")
end

--- Winbar expression: the winbar is set to a self-evaluating `%!` call of
--- this function, so it always reflects current buffer state on redraw —
--- no imperative refresh calls anywhere.
function M.winbar(buf)
  buf = buf or tonumber(vim.g.actual_curbuf) or vim.api.nvim_get_current_buf()
  return render_winbar(buf)
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
  spinner_timer:start(0, 100, vim.schedule_wrap(function()
    spinner_tick = spinner_tick + 1
    for b in pairs(running) do
      drain_tail(b) -- pull new tool output into the tail buffers
    end
    vim.cmd.redrawstatus() -- re-evaluates the winbar expression
    spinner_stop_if_idle()
  end))
end

local function define_winbar_hl()
  local links = { Model = "Keyword", Busy = "DiagnosticOk", Idle = "Comment", Error = "DiagnosticError" }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, "Pitel" .. name, { default = true, link = link })
  end
end

define_winbar_hl()

-- ─── Buffer ↔ messages ─────────────────────────────────────────────────────

--- Parse a pitel buffer into a message list.
--- Lines before the first heading are ignored (legacy frontmatter in
--- old session files stays inert).
--- `<!-- pitel:... -->` marker regions (thinking, error, ui) are excluded.
--- `<!-- pitel:tool -->` regions are TRANSFORMED (R12): the header becomes
--- an assistant tool_calls entry, the body becomes the tool result message.
--- Adjacent same-role blocks are merged (providers require alternation),
--- except tool-bearing assistant messages, which must stay adjacent to
--- their results.
--- Empty blocks are dropped.
function M.parse_buffer(buf)
  local messages = {}
  local role, acc = nil, {}
  local tools = {} -- pitel:tool regions collected in the current block
  local tool = nil -- open region: { call = <wire call>, result = {lines} }
  local skipping = false -- skipping a region (bad header / wrong role)
  local in_marker = false
  local ui_paired = false -- inside a paired `<!-- pitel:ui --> … <!-- /pitel:ui -->` diff
  local header_acc = nil -- collecting a multi-line tool header

  local function flush()
    if not role then
      acc = {} -- pre-heading lines (legacy frontmatter) are not a message
      return
    end
    local text = table.concat(acc, "\n")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if #tools > 0 then
      -- Tool-bearing assistant message + its results; never merged.
      local calls = {}
      for _, t in ipairs(tools) do
        table.insert(calls, t.call)
      end
      table.insert(messages, { role = "assistant", content = text, tool_calls = calls })
      for _, t in ipairs(tools) do
        local result = table.concat(t.result, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
        table.insert(messages, { role = "tool", tool_call_id = t.id, content = result })
      end
    elseif text ~= "" then
      local last = messages[#messages]
      -- Don't merge onto a tool-bearing assistant message: its results
      -- must directly follow it.
      if last and last.role == role and not last.tool_calls then
        last.content = last.content .. "\n\n" .. text
      else
        table.insert(messages, { role = role, content = text })
      end
    end
    acc = {}
    tools = {}
  end

  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if tool then
      -- Inside a pitel:tool region: collect the result, skip the
      -- display-only pitel:ui section (legacy multi-line comment form,
      -- or the paired form: `<!-- pitel:ui -->` … fence …
      -- `<!-- /pitel:ui -->`).
      if line:match("^<!%-%- /pitel:tool") then
        table.insert(tools, tool)
        tool = nil
        ui_paired = false
      elseif line:match("^<!%-%- /pitel:ui") then
        ui_paired = false
      elseif ui_paired then
        -- block-level diff content between the paired markers
      elseif line:match("^<!%-%- pitel:ui %-%->%s*$") then
        ui_paired = true
      elseif line:match("^<!%-%- pitel:ui") then
        -- legacy multi-line comment form: skip until a bare `-->`
        in_marker = not line:match("%-%->")
      elseif in_marker then
        if line:match("^%-%->$") then
          in_marker = false
        end
      else
        table.insert(tool.result, line)
      end
    elseif skipping then
      if line:match("^<!%-%- /pitel:tool") then
        skipping = false
      end
    elseif header_acc then
      -- Multi-line tool header: JSON lines until the closing `-->`.
      if line:match("^%-%->%s*$") then
        local ok, h = pcall(vim.json.decode, table.concat(header_acc, "\n"))
        if ok and type(h) == "table" and h.id and h.name then
          local args = h.arguments
          tool = {
            id = h.id,
            call = {
              id = h.id,
              type = "function",
              ["function"] = {
                name = h.name,
                arguments = type(args) == "string" and args or vim.json.encode(args),
              },
            },
            result = {},
          }
        else
          skipping = true
          vim.notify("pitel: malformed pitel:tool header, region skipped", vim.log.levels.WARN)
        end
        header_acc = nil
      else
        table.insert(header_acc, line)
      end
    elseif in_marker then
      -- Markers close on a line that is exactly `-->`; content lines
      -- merely containing `-->` (diffs, prose) must not close early.
      if line:match("^%-%->$") then
        in_marker = false
      end
    else
      local header = line:match("^<!%-%- pitel:tool (.+) %-%->%s*$")
      if header and role == "assistant" then
        local ok, h = pcall(vim.json.decode, header)
        if ok and type(h) == "table" and h.id and h.name then
          local args = h.arguments
          tool = {
            id = h.id,
            call = {
              id = h.id,
              type = "function",
              ["function"] = {
                name = h.name,
                arguments = type(args) == "string" and args or vim.json.encode(args),
              },
            },
            result = {},
          }
        else
          skipping = true
          vim.notify("pitel: malformed pitel:tool header, region skipped", vim.log.levels.WARN)
        end
      elseif line:match("^<!%-%- pitel:tool%s*$") and role == "assistant" then
        header_acc = {} -- multi-line header form (long calls)
      elseif line:match("^<!%-%- pitel:tool") then
        skipping = true -- region outside an assistant block: orphan, skip
      elseif line:match("^<!%-%- pitel:%a+") then
        -- Single-line markers (`<!-- pitel:usage {...} -->`) close on the
        -- same line; otherwise the next content line would be swallowed.
        in_marker = not line:match("%-%->")
      else
        local r = line:match(HEAD)
        if r and roles[r] then
          flush()
          role = roles[r]
        else
          table.insert(acc, line)
        end
      end
    end
  end
  flush()

  return messages
end

-- ─── Streaming append ──────────────────────────────────────────────────────

local function append_text(buf, text)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local row = vim.api.nvim_buf_line_count(buf) - 1
  local col = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
  vim.api.nvim_buf_set_text(buf, row, col, row, col, vim.split(text, "\n", { plain = true }))
end

--- Windows whose cursor sits on the last line of `buf`: the user is
--- "following" the end of the conversation (pressed G, or was left there
--- by the previous chunk). Sampled BEFORE an append, because following
--- itself moves the cursor to the end.
local function following_windows(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  local wins = {}
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, w)
    if ok and cur[1] >= count then
      wins[#wins + 1] = w
    end
  end
  return wins
end

--- Pin `wins` to the end of the buffer after an append: the cursor goes to
--- the end of the last line, which scrolls the window the way streamed
--- terminal output does (minimal scroll, one line at a time). Neovim never
--- scrolls a window for an API edit, so following has to be explicit: the
--- view used to track the end only while an appended chunk happened to land
--- exactly on the cursor (an empty last line, i.e. a chunk ending in a
--- newline), and then stranded the cursor mid-line — which is why a reply
--- seemed to stop being followed partway through. A window scrolled away is
--- left alone, and nothing is moved from a non-normal mode: dragging the
--- cursor while the user types is worse than a stale view (R11).
local function follow_windows(buf, wins)
  if #wins == 0 or vim.api.nvim_get_mode().mode ~= "n" then
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)
  local last = vim.api.nvim_buf_get_lines(buf, count - 1, count, false)[1] or ""
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
      vim.api.nvim_win_set_cursor(w, { count, math.max(#last - 1, 0) })
    end
  end
end

--- Append whole lines as a new block, separated from the buffer's current
--- end by exactly one blank line (R7), no matter how the buffer ends.
--- All structural appends (headings, error markers) go through here.
local function append_block(buf, block)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local n = vim.api.nvim_buf_line_count(buf)
  local keep = n
  while keep > 1 and vim.api.nvim_buf_get_lines(buf, keep - 1, keep, false)[1] == "" do
    keep = keep - 1
  end
  local lines = vim.deepcopy(block)
  table.insert(lines, 1, "")
  vim.api.nvim_buf_set_lines(buf, keep, n, false, lines)
end

-- ─── Templates & skills ────────────────────────────────────────────────────

--- `*.md` files in `dir`, sorted by name; empty when the dir is missing.
local function list_md(dir)
  local out = {}
  for _, path in ipairs(vim.fn.glob(vim.fn.expand(dir) .. "/*.md", false, true)) do
    out[#out + 1] = { path = path, name = vim.fn.fnamemodify(path, ":t:r") }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

--- Split optional YAML frontmatter (`---` ... `---`) off a skill file and
--- return its `description:` key (feeds the intro list) plus the body lines.
local function skill_parts(text)
  local description
  local lines = vim.split(text, "\n", { plain = true })
  if lines[1] and lines[1]:match("^%-%-%-%s*$") then
    local close
    for i = 2, #lines do
      if lines[i]:match("^%-%-%-%s*$") then
        close = i
        break
      end
      local d = lines[i]:match("^description:%s*(.*)%s*$")
      if d then
        description = d
      end
    end
    if close then
      local rest = {}
      for i = close + 1, #lines do
        rest[#rest + 1] = lines[i]
      end
      lines = rest
    end
  end
  return description, lines
end

local function trim_blank(lines)
  while #lines > 0 and lines[1]:match("^%s*$") do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return lines
end

--- All insertable entries: templates first, then skills (picker label
--- prefixed `skill: ` so the two kinds stay distinguishable).
local function template_entries()
  local entries = {}
  for _, t in ipairs(list_md(M.config.templates_dir)) do
    entries[#entries + 1] = { label = t.name, name = t.name, path = t.path, kind = "template" }
  end
  for _, s in ipairs(list_md(M.config.skills_dir)) do
    entries[#entries + 1] = { label = "skill: " .. s.name, name = s.name, path = s.path, kind = "skill" }
  end
  return entries
end

--- Append a template as a message block: a leading `# @role` heading is
--- used as-is (so a template can be a prefill or raw block); otherwise the
--- text is wrapped in `# @user`. Blank-line handling is append_block's (R7).
local function append_as_block(buf, lines)
  if #lines == 0 then
    vim.notify("pitel: template is empty", vim.log.levels.WARN)
    return
  end
  if not lines[1]:match(HEAD) then
    local wrapped = { "# @user", "" }
    vim.list_extend(wrapped, lines)
    lines = wrapped
  end
  append_block(buf, lines)
end

--- Merge a skill's body into the buffer's `# @system` block (or create the
--- block at the top when there is none). Skills are system-prompt material:
--- they go where a stateless provider keeps instructions.
local function merge_into_system(buf, lines)
  if #lines == 0 then
    vim.notify("pitel: skill is empty", vim.log.levels.WARN)
    return
  end
  local blines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local sys
  for i, l in ipairs(blines) do
    if l:match("^# @system%s*$") then
      sys = i
      break
    end
  end
  if not sys then
    local top = { "# @system", "" }
    vim.list_extend(top, lines)
    top[#top + 1] = ""
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, top)
    return
  end
  local last = #blines
  for i = sys + 1, #blines do
    if blines[i]:match(HEAD) then
      last = i - 1
      break
    end
  end
  while last >= sys and blines[last]:match("^%s*$") do
    last = last - 1
  end
  local ins = { "" }
  vim.list_extend(ins, lines)
  vim.api.nvim_buf_set_lines(buf, last, last, false, ins)
end

--- Insert `lines` as new lines above the cursor's line (the raw primitive).
local function insert_at_cursor(buf, lines)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  vim.api.nvim_buf_set_lines(buf, row, row, false, vim.deepcopy(lines))
end

--- Skills intro for new chats: a short `## Skills` list (name + frontmatter
--- description) in the system block — discoverability, not auto-load.
--- Returns nil when there are no skills.
local function skills_intro_lines()
  local lines = {}
  for _, s in ipairs(list_md(M.config.skills_dir)) do
    local text = read_file(s.path)
    if text then
      local description = skill_parts(text)
      lines[#lines + 1] = "- " .. s.name .. (description and (": " .. description) or "")
    end
  end
  return #lines > 0 and lines or nil
end

--- :PitelInsert [name] / :PitelInsertHere [name].
--- `opts.at_cursor` (default false) inserts verbatim above the cursor;
--- otherwise a template appends as a message block and a skill merges into
--- the system block. With no name, pick from the combined list.
function M.insert(name, opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  if not vim.b[buf].pitel then
    vim.notify("pitel: not a pitel buffer", vim.log.levels.WARN)
    return
  end
  if running[buf] then
    vim.notify("pitel: send in flight, not inserting", vim.log.levels.WARN)
    return
  end

  local function apply(entry)
    local text = read_file(entry.path)
    if not text then
      vim.notify("pitel: cannot read " .. entry.path, vim.log.levels.ERROR)
      return
    end
    local lines
    if entry.kind == "skill" then
      _, lines = skill_parts(text)
    else
      lines = vim.split(text, "\n", { plain = true })
    end
    lines = trim_blank(lines)
    if opts.at_cursor then
      insert_at_cursor(buf, lines)
    elseif entry.kind == "skill" then
      merge_into_system(buf, lines)
    else
      append_as_block(buf, lines)
    end
  end

  local entries = template_entries()
  if name then
    for _, e in ipairs(entries) do
      if e.name == name then
        apply(e)
        return
      end
    end
    vim.notify("pitel: no template/skill named: " .. name, vim.log.levels.WARN)
    return
  end
  if #entries == 0 then
    vim.notify(
      ("pitel: no templates in %s or %s"):format(M.config.templates_dir, M.config.skills_dir),
      vim.log.levels.WARN
    )
    return
  end
  local items = {}
  for _, e in ipairs(entries) do
    items[#items + 1] = e.label
  end
  vim.ui.select(items, { prompt = "pitel insert" }, function(choice)
    if not choice then
      return
    end
    for _, e in ipairs(entries) do
      if e.label == choice then
        apply(e)
        return
      end
    end
  end)
end

--- Completion list for :PitelInsert / :PitelInsertHere.
function M.template_names()
  local names = {}
  for _, e in ipairs(template_entries()) do
    names[#names + 1] = e.name
  end
  return names
end

--- Find the pitel:usage marker the binary appended for this turn, fold its
--- numbers into the buffer's session totals (winbar), and remove the marker.
local function consume_usage(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = #lines, 1, -1 do
    local json = lines[i]:match("^<!%-%- pitel:usage (.+) %-%->$")
    if json then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, {})
      local ok, data = pcall(vim.json.decode, json)
      if ok and type(data) == "table" then
        local u = vim.b[buf].pitel_usage or { prompt = 0, completion = 0 }
        u.prompt = u.prompt + (data.prompt or 0)
        u.completion = u.completion + (data.completion or 0)
        if data.cost then
          u.cost = (u.cost or 0) + data.cost
        end
        vim.b[buf].pitel_usage = u
      end
      return
    end
  end
end

-- ─── Send ──────────────────────────────────────────────────────────────────

-- In-flight jobs per buffer (vim.SystemObj can't live in vim.b).
running = {}

-- Live tool per buffer while it runs: { name, log, since }. Set from
-- the binary's `pitel:event` stderr lines (bash announces the temp file
-- its output streams into), cleared on tool_end / process exit.
live = {}

-- Per-chat-buffer persistent tail: every tool call appends a
-- `$ command` header and its output (drained from the temp log) to ONE
-- nofile buffer, pitel://<session>-tail. :PitelLive opens it.
local tails = {} -- chat buf → { bufnr, offset, has_content, audit }

-- The tail buffer is ephemeral; the AUDIT LOG is its durable form:
-- ~/.pitel/audit/<cwd-slug>/<session>.log (same parent as the sessions
-- dir). Everything shown in the tail is appended there too, plus the
-- full tool_call arguments (the buffer's pitel:tool headers keep only
-- slimmed write/edit args, R12) and one journal line per turn — so
-- nothing the context doesn't carry is ever lost, which is what makes
-- :PitelClear safe. Append-only, survives restarts.
local function audit_path(buf)
  local slug = (vim.fs.normalize(vim.fn.getcwd()):gsub("[^%w%._-]", "-"))
  local path = vim.b[buf].pitel_path
  local base = path and vim.fn.fnamemodify(path, ":t:r")
    or vim.api.nvim_buf_get_name(buf):gsub("^pitel://", ""):gsub("[^%w%._-]", "-")
  return ("%s/.pitel/audit/%s/%s.log"):format(vim.fn.expand("~"), slug, base)
end

local function audit_write(buf, lines)
  local t = tails[buf]
  if not t then
    return
  end
  if not t.audit then
    t.audit = audit_path(buf)
    vim.fn.mkdir(vim.fn.fnamemodify(t.audit, ":h"), "p")
  end
  vim.fn.writefile(lines, t.audit, "a")
end

--- Point the audit log at the session file's name; a `:file` rename
--- (which also renames the session) renames the log to match.
local function audit_follow(buf)
  local t = tails[buf]
  if not t or not t.audit or not vim.b[buf].pitel_path then
    return
  end
  local want = audit_path(buf)
  if want ~= t.audit and vim.fn.filereadable(want) == 0 then
    vim.fn.mkdir(vim.fn.fnamemodify(want, ":h"), "p")
    if os.rename(t.audit, want) then
      t.audit = want
    end
  end
end

local function ensure_tail(buf)
  local t = tails[buf]
  if t and vim.api.nvim_buf_is_valid(t.bufnr) then
    return t
  end
  local tail = vim.api.nvim_create_buf(true, true) -- listed scratch buffer
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match("^pitel://") then
    name = name .. "-tail"
  else
    name = "pitel://" .. vim.fn.fnamemodify(name, ":t") .. "-tail"
  end
  vim.api.nvim_buf_set_name(tail, name)
  vim.bo[tail].bufhidden = "hide"
  t = { bufnr = tail, offset = 0 }
  tails[buf] = t
  return t
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
  append_text(t.bufnr, data)
  -- the audit log gets the same bytes (a line split across two drains
  -- lands as two log lines; cosmetic)
  audit_write(buf, vim.split(data:gsub("\n$", ""), "\n", { plain = true }))
  -- keep a visible tail window scrolled to the bottom
  for _, w in ipairs(vim.fn.win_findbuf(t.bufnr)) do
    vim.api.nvim_win_set_cursor(w, { vim.api.nvim_buf_line_count(t.bufnr), 0 })
  end
end

--- Handle one `pitel:event {json}` line from the binary's stderr.
local function handle_event(buf, json_line)
  local ok, ev = pcall(vim.json.decode, json_line)
  if not ok or type(ev) ~= "table" then
    return
  end
  if ev.type == "tool_start" and ev.log then
    live[buf] = { name = ev.name or "tool", log = ev.log, since = os.time() }
    local t = ensure_tail(buf)
    t.offset = 0
    local header = "$ " .. (ev.command or ev.name or "tool")
    append_text(t.bufnr, (t.has_content and "\n" or "") .. header .. "\n")
    t.has_content = true
    audit_write(buf, { ("=== %s %s"):format(os.date("%Y-%m-%dT%H:%M:%S"), header) })
  elseif ev.type == "tool_end" then
    drain_tail(buf) -- the log is complete; a small one is about to be deleted
    live[buf] = nil
  elseif ev.type == "tool_call" then
    -- Full arguments, emitted for every tool before it runs. bash's
    -- tool_start above already logged its command (that IS its args).
    if ev.name ~= "bash" then
      local t = ensure_tail(buf)
      audit_write(buf, { ("=== %s %s %s"):format(os.date("%Y-%m-%dT%H:%M:%S"), ev.name, ev.args or "") })
      local target = ""
      local ok2, a = pcall(vim.json.decode, ev.args or "")
      if ok2 and type(a) == "table" then
        target = a.path or a.url or a.command or ""
      end
      append_text(t.bufnr, (t.has_content and "\n" or "") .. ("• %s %s\n"):format(ev.name, target))
      t.has_content = true
    end
  elseif ev.type == "tool_result" then
    -- The full result text lands in the audit log — :PitelClear can
    -- then remove it from the context without losing anything. bash's
    -- output was already streamed to the log from its temp file.
    local lines = {}
    if ev.name ~= "bash" and ev.result then
      vim.list_extend(lines, vim.split(ev.result, "\n", { plain = true }))
    end
    table.insert(lines, ("--- %s %s (%s bytes)"):format(os.date("%Y-%m-%dT%H:%M:%S"), ev.name, ev.bytes or "?"))
    audit_write(buf, lines)
  elseif ev.type == "turn_end" then
    local t = ensure_tail(buf)
    local cost = ev.cost and (" · " .. string.format("$%.4g", ev.cost)) or ""
    local line = ("# %s turn %s: %d in · %d out%s · %.1fs"):format(
      os.date("%Y-%m-%dT%H:%M:%S"), ev.model or "?", ev.prompt or 0, ev.completion or 0, cost, (ev.ms or 0) / 1000)
    append_text(t.bufnr, (t.has_content and "\n" or "") .. line .. "\n")
    t.has_content = true
    audit_write(buf, { line })
  end
end

--- :PitelClear [keep] — replace the bodies of all but the last `keep`
--- (default 2) pitel:tool regions with a placeholder; the full output
--- stays in the audit log. Headers (the model's own tool_calls history)
--- and pitel:ui diffs stay. This is the one sanctioned rewrite of
--- existing lines (R16): the user owns the document, and clearing old
--- tool output is what keeps long sessions inside the context window.
function M.clear(buf, keep)
  buf = (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
  if running[buf] then
    vim.notify("pitel: send in flight, not clearing", vim.log.levels.WARN)
    return
  end
  keep = keep or 2
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- collect tool regions as { first body line, last body line } (1-based,
  -- inclusive); the body runs from after the header to the pitel:ui
  -- opener or the region closer
  local regions = {}
  local i = 1
  while i <= #lines do
    local body_start
    if lines[i]:match("^<!%-%- pitel:tool .+ %-%->%s*$") then
      body_start = i + 1 -- single-line header
    elseif lines[i]:match("^<!%-%- pitel:tool%s*$") then
      local j = i + 1 -- multi-line header: body after its closing -->
      while j <= #lines and not lines[j]:match("^%-%->%s*$") do
        j = j + 1
      end
      body_start = j + 1
    end
    if body_start then
      local j = body_start
      while j <= #lines
        and not lines[j]:match("^<!%-%- pitel:ui")
        and not lines[j]:match("^<!%-%- /pitel:tool")
      do
        j = j + 1
      end
      table.insert(regions, { body_start, j - 1 })
      i = j
    else
      i = i + 1
    end
  end
  local placeholder = ("[output cleared — full output in the audit log: %s]")
    :format(vim.fn.fnamemodify(audit_path(buf), ":t"))
  local cleared = 0
  for r = 1, #regions - keep do
    local s, e = regions[r][1], regions[r][2]
    if e >= s and not lines[s]:match("^%[output cleared") then
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
    ("pitel: cleared %d tool result%s (kept the last %d)"):format(cleared, cleared == 1 and "" or "s", keep),
    vim.log.levels.INFO
  )
end

--- Open the session's tail buffer (:PitelLive): one persistent log of
--- every tool call's output, not a new terminal per call. Opens even
--- before any tool has run (an empty tail that fills as tools execute).
function M.live(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local t = ensure_tail(buf)
  local wins = vim.fn.win_findbuf(t.bufnr)
  if #wins > 0 then
    vim.api.nvim_set_current_win(wins[1])
  else
    vim.cmd("botright 12split")
    vim.api.nvim_win_set_buf(0, t.bufnr)
  end
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(t.bufnr), 0 })
end

--- Record a backend error: notify, persist it in the winbar, and leave a
--- parse-excluded marker in the buffer as a record.
local function report_error(buf, err)
  errors[buf] = err
  -- The marker is an HTML comment: neutralize any `-->` in the error
  -- text so it can't close the comment early for markdown renderers.
  local block = { "<!-- pitel:error" }
  vim.list_extend(block, vim.split(err:gsub("%-%->", "-- >"), "\n", { plain = true }))
  table.insert(block, "-->")
  append_block(buf, block)
  vim.notify("pitel: " .. err, vim.log.levels.ERROR)
end

--- Close dangling regions left by an interrupted stream. :PitelStop
--- kills the binary, which os.Exit()s without emitting the closers for
--- whatever it was mid-way through: a thinking comment (close with
--- `-->`), a multi-line tool header (an unterminated comment: `-->`,
--- then the region closer), or a tool region whose header landed but
--- whose result didn't (`<!-- /pitel:tool -->`). Two flags suffice:
--- model text/thinking and tool regions never interleave. Idempotent;
--- cheap enough to run on every process exit.
local function repair_stream_tail(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local in_tool, comment_open = false, false
  for _, line in ipairs(lines) do
    if line:match("^<!%-%- /pitel:tool") then
      in_tool = false
    elseif line:match("^<!%-%- pitel:tool%s*$") then
      in_tool, comment_open = true, true -- multi-line header comment
    elseif line:match("^<!%-%- pitel:tool .+ %-%-%>%s*$") then
      in_tool = true -- single-line header: comment closed, region open
    elseif line:match("^<!%-%- pitel:%a+%s*$") then
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
    table.insert(block, "<!-- /pitel:tool -->")
  end
  if #block > 0 then
    vim.api.nvim_buf_set_lines(buf, #lines, #lines, false, block)
  end
end

--- Serialize the current buffer and stream the assistant reply into it.
function M.send()
  local buf = vim.api.nvim_get_current_buf()
  if running[buf] then
    vim.notify("pitel: already streaming (stop with :PitelStop)", vim.log.levels.WARN)
    return
  end

  local messages = M.parse_buffer(buf)
  if #messages == 0 then
    vim.notify("pitel: nothing to send (write under a # @user heading)", vim.log.levels.WARN)
    return
  end

  errors[buf] = nil
  -- provider/model come from the buffer vars (set by :Pitel /
  -- :PitelChangeModel), falling back to config; sync them so the winbar
  -- and this send agree.
  local provider, model = current_combo(buf)
  vim.b[buf].pitel_provider = provider
  vim.b[buf].pitel_model = model

  -- A window already watching the end keeps watching it while the reply
  -- streams (follow_windows); one parked elsewhere is not dragged along.
  local follow = following_windows(buf)
  append_block(buf, { "# @assistant", "" })
  -- Mark that a reply has streamed here: the folder keeps the latest
  -- assistant block open in view 1 so the reply is visible as it arrives
  -- (R10: the new assistant block opens by itself); older replies fold.
  vim.b[buf].pitel_live = true
  follow_windows(buf, follow)
  -- Sends never touch fold state or rewrite existing lines: the buffer
  -- is always in its final format, streaming only appends at the end,
  -- and new folds adopt the view's 'foldlevel' as they appear (R10) —
  -- the new assistant block opens by itself in every view.
  spinner_start()

  local payload = vim.json.encode({ messages = messages })
  local stderr_chunks = {}
  local stderr_partial = "" -- event lines can split across chunks

  local ok, handle = pcall(vim.system, { M.config.bin, "send", "--provider", provider, "--model", model }, {
    stdin = payload,
    text = true,
    stdout = vim.schedule_wrap(function(_, data)
      if data then
        -- Appending never touches fold state: new folds adopt the
        -- view's 'foldlevel' as they appear (R10).
        local follow = following_windows(buf)
        append_text(buf, data)
        follow_windows(buf, follow)
      end
    end),
    stderr = vim.schedule_wrap(function(_, data)
      if not data then
        return
      end
      -- stderr mixes error text with `pitel:event {json}` lines (tool
      -- progress); route complete lines, keep the rest for errors.
      stderr_partial = stderr_partial .. data
      while true do
        local i = stderr_partial:find("\n", 1, true)
        if not i then
          break
        end
        local line = stderr_partial:sub(1, i - 1)
        stderr_partial = stderr_partial:sub(i + 1)
        local ev = line:match("^pitel:event (.+)$")
        if ev then
          handle_event(buf, ev)
        else
          table.insert(stderr_chunks, line)
        end
      end
    end),
  }, vim.schedule_wrap(function(result)
    running[buf] = nil
    drain_tail(buf) -- final bytes; a killed tool never sent tool_end
    live[buf] = nil
    spinner_stop_if_idle()
    repair_stream_tail(buf)
    if stderr_partial ~= "" then
      table.insert(stderr_chunks, stderr_partial)
    end
    if result.code ~= 0 then
      local err = table.concat(stderr_chunks, "\n"):gsub("%s+$", "")
      report_error(buf, err ~= "" and err or ("exit " .. result.code))
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
        local err = l:match("^<!%-%- pitel:error$") and lines[i + 1]
        if err then
          errors[buf] = err
          vim.notify("pitel: " .. err, vim.log.levels.WARN)
          break
        end
      end
    end
    append_block(buf, { "# @user", "" })
    require("harness.session").save(buf)
    audit_follow(buf) -- first save named the session; rename the log to match
    if vim.api.nvim_get_current_buf() == buf then
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end))

  if not ok then
    spinner_stop_if_idle()
    report_error(buf, tostring(handle))
    return
  end

  running[buf] = handle
end

--- Kill the in-flight request for the current buffer.
function M.stop()
  local buf = vim.api.nvim_get_current_buf()
  local handle = running[buf]
  if handle then
    handle:kill(15)
    running[buf] = nil
    spinner_stop_if_idle()
  end
end

-- ─── Buffers ───────────────────────────────────────────────────────────────

-- Keymaps and buffer options shared by new and reopened session buffers.
local function setup_buffer(buf)
  -- Mark the buffer as a pitel conversation BEFORE the filetype triggers the
  -- LSP's FileType autocommand, so the LspAttach guard in M.setup can see it.
  -- A chat buffer is not code: markdown LSPs (semantic tokens, inlay hints)
  -- add per-redraw cost on a large session and buy nothing (R1).
  vim.b[buf].pitel = true
  -- Opening a saved session (:edit) sets the filetype before setup_buffer
  -- runs, so a markdown client may already be attached; stop it.
  if vim.lsp and vim.lsp.get_clients then
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
      pcall(vim.lsp.stop_client, client.id)
    end
  end

  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide"

  local map = function(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  map("n", "<C-s>", M.send, "pitel: send")
  map("i", "<C-s>", function()
    vim.cmd.stopinsert()
    M.send()
  end, "pitel: send")
  map("n", "<leader>m", function()
    M.change_model()
  end, "pitel: change model")
  map("n", "<leader>l", function()
    M.live()
  end, "pitel: live tool output")
  map("n", "<leader>t", function()
    M.insert()
  end, "pitel: insert template or skill")
  map("n", "<leader>T", function()
    M.insert(nil, { at_cursor = true })
  end, "pitel: insert template or skill at cursor")

  require("harness.fold").setup_buffer(buf)

  -- Self-evaluating winbar: a pure function of buffer state, refreshed
  -- by Neovim on every redraw.
  vim.wo.winbar = "%!v:lua.require'harness'.winbar()"
end

--- Open a new pitel chat buffer.
function M.new(opts)
  opts = opts or {}
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].pitel_provider = opts.provider or M.config.provider
  vim.b[buf].pitel_model = opts.model or M.config.model

  local lines = { "# @system", "" }
  vim.list_extend(lines, vim.split(vim.b[buf].pitel_system or system_prompt(), "\n", { plain = true }))
  if M.config.skills_intro then
    local intro = skills_intro_lines()
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
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })

  setup_buffer(buf)

  return buf
end

--- Open a saved session file as a pitel buffer.
function M.open(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].pitel_path = path
  -- Resume the recorded combo; legacy files without frontmatter keep the
  -- config default. Nothing is injected on open — that would dirty the
  -- buffer the moment it is resumed.
  local e = frontmatter_end(buf)
  if e then
    local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
    if fm and fm.provider and fm.provider ~= "" and fm.model and fm.model ~= "" then
      vim.b[buf].pitel_provider = fm.provider
      vim.b[buf].pitel_model = fm.model
    end
  end
  setup_buffer(buf)
  return buf
end

--- Change the provider/model combo for the current buffer.
--- With an argument: "provider/model". Without: pick from setup()'s
--- models list, or — when that isn't configured — from `pitel models`,
--- which queries every provider in config.json (GET /models).
function M.change_model(combo)
  local buf = vim.api.nvim_get_current_buf()
  if not combo then
    local function pick(items)
      vim.ui.select(items, { prompt = "pitel model" }, function(choice)
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
          vim.notify("pitel: no models found" .. (err ~= "" and (": " .. err) or ""), vim.log.levels.WARN)
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
    vim.notify("pitel: expected provider/model, got: " .. combo, vim.log.levels.ERROR)
    return
  end
  vim.b[buf].pitel_provider = provider
  vim.b[buf].pitel_model = model
  sync_frontmatter(buf) -- persist: combo + used-models history live in the buffer
  vim.notify("pitel: " .. provider .. "/" .. model)
end

--- Pick a saved session and open it. scope: "cwd" (default) or "all".
function M.sessions(scope)
  require("harness.session").pick({ scope = scope }, function(path)
    M.open(path)
  end)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- pitel buffers carry no language server: the buffer is the conversation
  -- (R1), and a markdown LSP streaming semantic-token/inlay-hint updates is
  -- pure per-redraw cost. The guard stops any client that attaches to a
  -- marked buffer; setup_buffer marks the buffer and stops clients that
  -- attached during :edit before the mark existed.
  local group = vim.api.nvim_create_augroup("PitelLsp", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      if vim.b[args.buf].pitel and args.data and args.data.client_id then
        pcall(vim.lsp.stop_client, args.data.client_id)
      end
    end,
  })
end

return M
