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

--- The combo pitel will send with: per-buffer vars (set by :PitelNew),
--- falling back to the global config.
local function current_combo(buf)
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
      -- Inside a pitel:tool region: collect the result, skip pitel:ui.
      if line:match("^<!%-%- /pitel:tool") then
        table.insert(tools, tool)
        tool = nil
      elseif line:match("^<!%-%- pitel:ui") then
        -- Single-line form closes on the same line.
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
  -- provider/model come from the buffer vars (set by :PitelNew /
  -- :PitelChangeModel), falling back to config; sync them so the winbar
  -- and this send agree.
  local provider, model = current_combo(buf)
  vim.b[buf].pitel_provider = provider
  vim.b[buf].pitel_model = model

  append_block(buf, { "# @assistant", "" })
  -- Sends never touch fold state or rewrite existing lines: the buffer is
  -- always in its final format, streaming only appends at the end, and
  -- tool-argument folds close chunk by chunk in the stdout handler.
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
        require("harness.fold").close_tool_folds(buf)
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
    if result.code ~= 0 then
      local err = table.concat(stderr_chunks):gsub("%s+$", "")
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
  map("n", "<leader>m", function()
    M.change_model()
  end, "pitel: change model")

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
  vim.list_extend(lines, { "", "# @user", "" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- A pitel:// name keeps file-backed clients (markdown LSPs) off the
  -- session buffer and leaves 'modified' set, so an unsent new chat
  -- prompts like any unsaved buffer instead of vanishing on :q!.
  vim.api.nvim_buf_set_name(buf, ("pitel://%s-%d"):format(os.date("%Y%m%d-%H%M%S"), buf))
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })

  setup_buffer(buf)

  return buf
end

--- Open a saved session file as a pitel buffer.
function M.open(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].pitel_path = path
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
end

return M
