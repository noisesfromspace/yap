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
  -- Optional list of valid "provider/model" combos, shown as a hint line
  -- in the session header (pi's scoped model names).
  models = nil,
  -- System prompt for new buffers: read from agents_file if it exists
  -- (pi-style ~/.pitel/AGENTS.md), otherwise this fallback.
  system = "You are a helpful coding assistant. Answer concisely.",
  agents_file = vim.fn.expand("~/.pitel/AGENTS.md"),
}

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

--- Scan the frontmatter; returns a table of its key/value pairs (and the
--- end line in _end), or nil when there is none.
local function frontmatter(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 20, false)
  if lines[1] ~= "---" then
    return nil
  end
  local fm = {}
  for i = 2, #lines do
    if lines[i] == "---" then
      fm._end = i
      return fm
    end
    local k, v = lines[i]:match("^(%S+):%s*(.-)%s*$")
    if k then
      fm[k] = v
    end
  end
  return nil -- unterminated
end

--- provider/model combo from the frontmatter, nil if not parseable.
local function header_combo(buf)
  local fm = frontmatter(buf)
  if fm and fm.provider and fm.provider ~= "" and fm.model and fm.model ~= "" then
    return fm.provider, fm.model
  end
end

--- The combo pitel will send with: the header is authoritative, then the
--- per-buffer var, then the global config.
local function current_combo(buf)
  local p, m = header_combo(buf)
  if p then
    return p, m
  end
  return vim.b[buf].pitel_provider or M.config.provider, vim.b[buf].pitel_model or M.config.model
end

-- ─── Winbar (busy indicator, provider/model) ──────────────────────────────

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_tick = 0
local spinner_timer = nil

-- Forward declaration: `running` is defined with the send logic below.
local running

local function winbar_hl(text, group)
  return "%#Pitel" .. group .. "#" .. text .. "%*"
end

-- Last backend error per buffer; shown in the winbar until the next send.
local errors = {}

local function render_winbar(buf)
  local provider, model = current_combo(buf)
  local parts = {
    winbar_hl(" " .. provider .. " / " .. model .. " ", "Model"),
    "%=",
  }
  if running and running[buf] then
    local frame = SPINNER[(spinner_tick % #SPINNER) + 1]
    table.insert(parts, winbar_hl(" " .. frame .. " busy ", "Busy"))
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

--- Normalize spacing: every message heading is preceded by exactly one
--- blank line (except at the top of the buffer), and the buffer has no
--- trailing blank lines. Keeps blocks visually separated no matter how
--- the user edited the buffer.
local function normalize_spacing(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local out = {}
  for _, line in ipairs(lines) do
    if line:match(HEAD) and #out > 0 then
      while out[#out] == "" do
        table.remove(out)
      end
      table.insert(out, "")
    end
    table.insert(out, line)
  end
  while out[#out] == "" do
    table.remove(out)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
end

--- Parse a pitel buffer into a message list.
--- Lines before the first heading are ignored (frontmatter).
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
  local header_acc = nil -- collecting a multi-line tool header

  local function flush()
    if not role then
      acc = {} -- pre-heading lines (frontmatter) are not a message
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
      -- Inside a pitel:tool region: collect the result, skip pitel:ui.
      if line:match("^<!%-%- /pitel:tool") then
        table.insert(tools, tool)
        tool = nil
      elseif line:match("^<!%-%- pitel:ui") then
        -- Single-line form closes on the same line.
        in_marker = not line:match("%-%->")
      elseif in_marker then
        if line:match("%-%->") then
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
      if line:match("%-%->") then
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

-- ─── Session header (YAML frontmatter) ─────────────────────────────────────

-- Session metadata is YAML frontmatter at the very top of the buffer,
-- before the first heading (so parse_buffer ignores it). Standard format:
-- treesitter highlights it as YAML, fields are trivial to parse and edit.
-- Editing provider/model switches the model (R14).

local function header_state(buf)
  local u = vim.b[buf].pitel_usage or {}
  return {
    started = vim.b[buf].pitel_started or os.date("%Y-%m-%d %H:%M"),
    prompt = u.prompt or 0,
    completion = u.completion or 0,
    cost = u.cost,
  }
end

local function render_header(buf)
  local s = header_state(buf)
  local provider, model = current_combo(buf)
  local lines = {
    "---",
    "provider: " .. provider,
    "model: " .. model,
    "started: " .. s.started,
    "tokens_in: " .. s.prompt,
    "tokens_out: " .. s.completion,
  }
  if s.cost then
    table.insert(lines, "cost: " .. string.format("%.6g", s.cost)) -- keep precision: parsed back on reopen
  end
  if M.config.models and #M.config.models > 0 then
    table.insert(lines, "# try: " .. table.concat(M.config.models, " · "))
  end
  table.insert(lines, "---")
  table.insert(lines, "")

  local fm = frontmatter(buf)
  if fm then
    -- replace existing frontmatter block (--- .. --- inclusive)
    vim.api.nvim_buf_set_lines(buf, 0, fm._end, false, lines)
  else
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, lines)
  end
end

--- Restore combo/started/usage from the frontmatter of a reopened session
--- buffer. Falls back to the old comment header formats if present.
local function parse_header(buf)
  local fm = frontmatter(buf)
  if fm then
    if fm.provider and fm.model then
      vim.b[buf].pitel_provider = fm.provider
      vim.b[buf].pitel_model = fm.model
    end
    vim.b[buf].pitel_started = fm.started
    vim.b[buf].pitel_usage = {
      prompt = tonumber(fm.tokens_in) or 0,
      completion = tonumber(fm.tokens_out) or 0,
      cost = tonumber(fm.cost),
    }
    return true
  end
  -- legacy: <!-- pitel session ... --> header (one-liner or with JSON line)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 5, false)
  local first = lines[1]
  if not (first and first:match("^<!%-%- pitel session")) then
    return false
  end
  local p, m = first:match("pitel session · ([%w_.:-]+)/([%w_.:-]+)")
  if p then
    vim.b[buf].pitel_provider = p
    vim.b[buf].pitel_model = m
  end
  local started, pin, pout, cost =
    first:match("started ([%d%-]+ [%d:]+) · ([%d,]+) in / ([%d,]+) out · %$([%d.]+)")
  if not started then
    started, pin, pout = first:match("started ([%d%-]+ [%d:]+) · ([%d,]+) in / ([%d,]+) out")
  end
  if started then
    vim.b[buf].pitel_started = started
    vim.b[buf].pitel_usage = {
      prompt = tonumber((pin:gsub(",", ""))),
      completion = tonumber((pout:gsub(",", ""))),
      cost = cost and tonumber(cost) or nil,
    }
    return true
  end
  for i = 2, #lines do
    local ok, data = pcall(vim.json.decode, lines[i])
    if ok and type(data) == "table" and data.started then
      vim.b[buf].pitel_started = data.started
      vim.b[buf].pitel_usage = { prompt = data.prompt or 0, completion = data.completion or 0, cost = data.cost }
      return true
    end
  end
  return true
end

--- Find the pitel:usage marker the binary appended for this turn, fold its
--- numbers into the session totals, remove the marker and refresh the header.
local function consume_usage(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = #lines, 1, -1 do
    local json = lines[i]:match("^<!%-%- pitel:usage (.+) %-%->$")
    if json then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, {})
      local ok, data = pcall(vim.json.decode, json)
      if ok and type(data) == "table" then
        local s = header_state(buf)
        s.prompt = s.prompt + (data.prompt or 0)
        s.completion = s.completion + (data.completion or 0)
        if data.cost then
          s.cost = (s.cost or 0) + data.cost
        end
        vim.b[buf].pitel_started = s.started
        vim.b[buf].pitel_usage = { prompt = s.prompt, completion = s.completion, cost = s.cost }
      end
      render_header(buf)
      return
    end
  end
end

-- ─── Send ──────────────────────────────────────────────────────────────────

-- In-flight jobs per buffer (vim.SystemObj can't live in vim.b).
running = {}

--- Record a backend error: notify, persist it in the winbar, and leave a
--- parse-excluded marker in the buffer as a record.
local function report_error(buf, err)
  errors[buf] = err
  local block = { "<!-- pitel:error" }
  vim.list_extend(block, vim.split(err, "\n", { plain = true }))
  table.insert(block, "-->")
  append_block(buf, block)
  vim.notify("pitel: " .. err, vim.log.levels.ERROR)
end

--- Serialize the current buffer and stream the assistant reply into it.
function M.send()
  local buf = vim.api.nvim_get_current_buf()
  if running[buf] then
    vim.notify("pitel: already streaming (stop with :PitelStop)", vim.log.levels.WARN)
    return
  end

  normalize_spacing(buf)
  local messages = M.parse_buffer(buf)
  if #messages == 0 then
    vim.notify("pitel: nothing to send (write under a # @user heading)", vim.log.levels.WARN)
    return
  end

  errors[buf] = nil
  -- The header's provider/model combo is authoritative (R14); sync the
  -- buffer vars so the winbar and future header renders agree.
  local provider, model = current_combo(buf)
  vim.b[buf].pitel_provider = provider
  vim.b[buf].pitel_model = model

  append_block(buf, { "# @assistant", "" })
  -- Fold history to the outline; the new assistant block is last, so it
  -- stays open while it streams.
  require("pitel.fold").apply_default_folds(buf)
  spinner_start()

  local payload = vim.json.encode({ messages = messages })
  local stderr_chunks = {}

  local ok, handle = pcall(vim.system, { M.config.bin, "send", "--provider", provider, "--model", model }, {
    stdin = payload,
    text = true,
    stdout = vim.schedule_wrap(function(_, data)
      if data then
        append_text(buf, data)
        -- Tool-argument folds don't close themselves as they stream in
        -- (expr folds only get state from explicit commands), and the
        -- opener may arrive chunks before its fold exists — so close on
        -- every chunk; foldclose is a no-op when there's nothing to do.
        require("pitel.fold").close_tool_folds(buf)
      end
    end),
    stderr = function(_, data)
      if data then
        table.insert(stderr_chunks, data)
      end
    end,
  }, vim.schedule_wrap(function(result)
    running[buf] = nil
    spinner_stop_if_idle()
    normalize_spacing(buf)
    if result.code ~= 0 then
      local err = table.concat(stderr_chunks):gsub("%s+$", "")
      report_error(buf, err ~= "" and err or ("exit " .. result.code))
      return
    end
    consume_usage(buf)
    normalize_spacing(buf)
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
    require("pitel.session").save(buf)
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

  require("pitel.fold").setup_buffer(buf)

  -- Self-evaluating winbar: a pure function of buffer state (R14 combo
  -- edits included), refreshed by Neovim on every redraw.
  vim.wo.winbar = "%!v:lua.require'pitel'.winbar()"
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
  vim.list_extend(lines, { "", "# @user", "" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.b[buf].pitel_started = os.date("%Y-%m-%d %H:%M")
  render_header(buf)
  -- Named after creation time (bufnr for uniqueness) so `:ls` is
  -- meaningful before the first save renames it to the session file.
  vim.api.nvim_buf_set_name(buf, ("pitel://%s-%d"):format(os.date("%Y%m%d-%H%M%S"), buf))
  vim.bo[buf].modified = false
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })

  setup_buffer(buf)

  return buf
end

--- Open a saved session file as a pitel buffer.
function M.open(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].pitel_path = path
  if not parse_header(buf) then
    -- Pre-header session: adopt the file's mtime as the start date.
    vim.b[buf].pitel_started = os.date("%Y-%m-%d %H:%M", vim.fn.getftime(path))
  end
  render_header(buf)
  setup_buffer(buf)
  return buf
end

--- Pick a saved session and open it. scope: "cwd" (default) or "all".
function M.sessions(scope)
  require("pitel.session").pick({ scope = scope }, function(path)
    M.open(path)
  end)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

return M
