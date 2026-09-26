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
  local provider = vim.b[buf].pitel_provider or M.config.provider
  local model = vim.b[buf].pitel_model or M.config.model
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

local function refresh_winbar(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local bar = render_winbar(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winbar = bar
    end
  end
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
    for buf in pairs(running) do
      refresh_winbar(buf)
    end
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
--- Lines before the first heading are ignored (header comments).
--- `<!-- pitel:... -->` regions (thinking, errors) are excluded: they are
--- shown in the buffer but never sent back to the provider.
--- Adjacent same-role blocks are merged (providers require alternation).
--- Empty blocks are dropped.
function M.parse_buffer(buf)
  local messages = {}
  local role, acc = nil, {}
  local in_marker = false

  local function flush()
    if not role then
      return
    end
    local text = table.concat(acc, "\n")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text ~= "" then
      local last = messages[#messages]
      if last and last.role == role then
        last.content = last.content .. "\n\n" .. text
      else
        table.insert(messages, { role = role, content = text })
      end
    end
    acc = {}
  end

  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match("^<!%-%- pitel:%a+") then
      in_marker = true
    elseif in_marker then
      if line:match("%-%->") then
        in_marker = false
      end
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

-- ─── Send ──────────────────────────────────────────────────────────────────

-- In-flight jobs per buffer (vim.SystemObj can't live in vim.b).
running = {}

--- Record a backend error: notify, persist it in the winbar, and leave a
--- parse-excluded marker in the buffer as a record.
local function report_error(buf, err)
  errors[buf] = err
  append_text(buf, "\n\n<!-- pitel:error\n" .. err .. "\n-->\n")
  refresh_winbar(buf)
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
  local provider = vim.b[buf].pitel_provider or M.config.provider
  local model = vim.b[buf].pitel_model or M.config.model

  append_text(buf, "\n# @assistant\n\n")
  -- Fold history to the outline; the new assistant block is last, so it
  -- stays open while it streams.
  require("pitel.fold").apply_default_folds(buf)
  refresh_winbar(buf)
  spinner_start()

  local payload = vim.json.encode({ messages = messages })
  local stderr_chunks = {}

  local ok, handle = pcall(vim.system, { M.config.bin, "send", "--provider", provider, "--model", model }, {
    stdin = payload,
    text = true,
    stdout = vim.schedule_wrap(function(_, data)
      if data then
        append_text(buf, data)
      end
    end),
    stderr = function(_, data)
      if data then
        table.insert(stderr_chunks, data)
      end
    end,
  }, vim.schedule_wrap(function(result)
    running[buf] = nil
    refresh_winbar(buf)
    spinner_stop_if_idle()
    normalize_spacing(buf)
    if result.code ~= 0 then
      local err = table.concat(stderr_chunks):gsub("%s+$", "")
      report_error(buf, err ~= "" and err or ("exit " .. result.code))
      return
    end
    append_text(buf, "\n\n# @user\n\n")
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
    refresh_winbar(buf)
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
  refresh_winbar(buf)
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
  -- Named after creation time (bufnr for uniqueness) so `:ls` is
  -- meaningful before the first save renames it to the session file.
  vim.api.nvim_buf_set_name(buf, ("pitel://%s-%d"):format(os.date("%Y%m%d-%H%M%S"), buf))
  vim.bo[buf].modified = false
  vim.api.nvim_win_set_cursor(0, { #lines, 0 })

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

--- Pick a saved session and open it. scope: "cwd" (default) or "all".
function M.sessions(scope)
  require("pitel.session").pick({ scope = scope }, function(path)
    M.open(path)
  end)
end

--- Switch provider/model for the current buffer.
function M.use(provider, model)
  local buf = vim.api.nvim_get_current_buf()
  if provider and provider ~= "" then
    vim.b[buf].pitel_provider = provider
  end
  if model and model ~= "" then
    vim.b[buf].pitel_model = model
  end
  refresh_winbar(buf)
  vim.notify(("pitel: %s / %s"):format(vim.b[buf].pitel_provider, vim.b[buf].pitel_model))
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

return M
