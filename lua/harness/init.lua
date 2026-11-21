-- yap.nvim — the buffer is the conversation.
--
-- A yap buffer is plain markdown. Headings of the form `# @user`,
-- `# @assistant` and `# @system` delimit messages; everything between
-- headings is message content. The buffer is the ONLY state: deleting a
-- message removes it from the conversation, editing an assistant reply
-- changes what the model "said", inserting a fake reply steers it.
-- gptel semantics, Neovim native.
--
-- Sending serializes the whole buffer to the `yap` binary, which talks
-- to the provider and streams the reply back into the buffer.
--
-- This module is the facade + composition root: it re-exports the public
-- API and wires the autocmds. The implementations live in sibling modules —
-- stream (send/cancel), buffers (open/fork/adopt), sessions (pickers/live
-- tail/reveal), maintain (clear/compact), and system (system prompt).

local M = {}

local paths = require("harness.path")
local config = require("harness.config")
local state = require("harness.state")
local frontmatter = require("harness.model.frontmatter")
local winbar = require("harness.ui.winbar")
local drawer = require("harness.ui.drawer")
local scratchmod = require("harness.client.scratch")
local describe = require("harness.client.describe")
local subagent = require("harness.client.subagent")
local template = require("harness.client.template")
local guard = require("harness.ui.guard")
local fold = require("harness.ui.fold")
local audit = require("harness.client.audit")
local session = require("harness.session")
local lsp = require("harness.client.lsp")
local util = require("harness.util")

local stream = require("harness.client.stream")
local buffers = require("harness.session.buffers")
local sessions = require("harness.session.sessions")
local maintain = require("harness.session.maintain")

M.config = config.defaults

M.winbar = winbar.winbar
M.overview = winbar.overview
M.steer = scratchmod.steer
M.scratch_send = scratchmod.scratch_send
M.scratch_foldexpr = scratchmod.scratch_foldexpr
M.scratch_toggle = scratchmod.scratch_toggle

-- ─── Facade re-exports ────────────────────────────────────────────────────

-- Turn lifecycle (stream).
M.send = stream.send
M.stop = stream.stop
M.answer_approval = stream.answer_approval

-- Guard board (ui).
M.guard = guard.toggle

-- Buffer lifecycle (buffers).
M.new = buffers.new
M.fork = buffers.fork
M.delete = buffers.delete
M.open = buffers.open
M.adopt = buffers.adopt

-- Session listing and navigation (sessions).
M.sessions = sessions.sessions
M.live = sessions.live
M.tail_buffer = sessions.tail_buffer
M.session_of = sessions.session_of
M.reveal_call = sessions.reveal_call

-- Session maintenance (maintain).
M.clear = maintain.clear
M.compact = maintain.compact

-- Session label (session).
M.session_label = session.live_label

-- ─── Thin delegates ───────────────────────────────────────────────────────

function M.insert(name, opts)
  return template.insert(name, opts)
end

--- Evaluate a visual selection through the model (one-shot, no tools): the
--- selected lines are replaced by the model's output. See |:YapEval|.
function M.eval(opts)
  return require("harness.client.eval").eval(opts)
end

--- Open an interactive eval session about a selection: a regular session that
--- is listed in sessions(). The source buffer is not changed. See |:YapEval|.
function M.eval_session(opts)
  return require("harness.client.eval").session(opts)
end

function M.is_running(buf)
  return state.is_running(buf)
end

--- The single leading badge for each reply, computed by the same resolver
--- that renders the closed-fold label, so the picker and the fold can never
--- disagree. Keyed by the owning `# @assistant` heading line.
local function symbol_badges(buf)
  local fold = require("harness.ui.fold")
  local p = require("harness.model.structure").parse(buf)
  local badges = {}
  for i, h in ipairs(p.headings) do
    if h.role == "assistant" then
      local finish = p.headings[i + 1] and (p.headings[i + 1].line - 1) or p.count
      local b = fold.assistant_badge(buf, h.line, finish)
      if b then
        badges[h.line] = b.label:gsub("%s+$", "")
      end
    end
  end
  return badges
end

--- Document-symbol picker: one symbol per message (newest first), then the
--- frontmatter block last, in the server's order. Subagent tool calls are
--- children of their message and are flattened into the list. Events that
--- badge a closed fold (a stopped turn, an accepted cost warning) also suffix
--- the matching message symbol. Generic document_symbol pickers (e.g.
--- mini.extra) re-sort by line number, which would put the frontmatter back on
--- top, so yap presents the outline itself through |vim.ui.select|.
function M.symbols(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local syms = lsp.symbols(buf)
  if not syms or #syms == 0 then
    vim.notify("yap: no symbols in this buffer", vim.log.levels.WARN, { title = "yap" })
    return
  end
  local badges = symbol_badges(buf)
  local items = {}
  for _, sym in ipairs(syms) do
    local label = badges[sym.line]
    items[#items + 1] = {
      name = label and (sym.name .. "  " .. label) or sym.name,
      line = sym.line,
    }
  end
  vim.ui.select(items, {
    prompt = "yap symbols",
    format_item = function(item)
      return item.name
    end,
  }, function(choice)
    if choice then
      vim.api.nvim_win_set_cursor(0, { choice.line, 0 })
    end
  end)
end

-- ─── Shared per-buffer state aliases (for the autocmds below) ─────────────

local running = state.running
local stopped = state.stopped
local live = state.live
local errors = state.errors
local last_turn = state.last_turn
local awaiting = state.awaiting
local servers = state.servers
local pending_approvals = state.pending_approvals

-- ─── User commands kept here (small, self-contained) ─────────────────────

function M.show_keymaps(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local modes = { "n", "i", "x", "o" }
  -- Group by lhs: one cheat-sheet row per key, not one per (key, mode).
  local by_lhs, order = {}, {}
  local function collect(maps, mode)
    for _, map in ipairs(maps) do
      if map.desc and map.desc:match("^yap:") then
        local desc = map.desc:sub(6)
        -- Native fold passthroughs (za, zc, zA, ...) describe nothing but
        -- their own key; they're stock Vim folds, not worth a row here.
        if desc ~= map.lhs then
          local g = by_lhs[map.lhs]
          if not g then
            g = { modes = {}, desc = nil, seen = {} }
            by_lhs[map.lhs] = g
            order[#order + 1] = map.lhs
          end
          local key = mode .. "\0" .. desc
          if not g.seen[key] then
            g.seen[key] = true
            g.modes[#g.modes + 1] = mode
            -- Prefer the normal-mode description when one exists.
            if mode == "n" or g.desc == nil then
              g.desc = desc
            end
          end
        end
      end
    end
  end
  for _, mode in ipairs(modes) do
    collect(vim.api.nvim_buf_get_keymap(buf, mode), mode)
    collect(vim.api.nvim_get_keymap(mode), mode)
  end
  table.sort(order)

  local MODE_ORDER = { "n", "i", "x", "o" }
  local function mode_string(a, b)
    local set = {}
    for _, m in ipairs(a) do
      set[m] = true
    end
    if b then
      for _, m in ipairs(b) do
        set[m] = true
      end
    end
    local out = {}
    for _, m in ipairs(MODE_ORDER) do
      if set[m] then
        out[#out + 1] = m
      end
    end
    return table.concat(out, " ")
  end

  -- Collapse paired prev/next keys ([a / ]a) into a single row.
  local rows, paired = {}, {}
  for _, lhs in ipairs(order) do
    if not paired[lhs] then
      local g = by_lhs[lhs]
      if lhs:sub(1, 1) == "[" then
        local other_lhs = "]" .. lhs:sub(2)
        local o = by_lhs[other_lhs]
        if o and not paired[other_lhs] then
          local a_suffix = g.desc:match("^Previous (.*)$")
          local b_suffix = o.desc:match("^Next (.*)$")
          local desc = a_suffix and b_suffix and a_suffix == b_suffix and ("Previous / Next " .. a_suffix)
            or (g.desc .. " / " .. o.desc)
          rows[#rows + 1] = {
            lhs = lhs .. " / " .. other_lhs,
            mode = mode_string(g.modes, o.modes),
            desc = desc,
          }
          paired[lhs], paired[other_lhs] = true, true
        else
          rows[#rows + 1] = { lhs = lhs, mode = mode_string(g.modes), desc = g.desc }
        end
      else
        rows[#rows + 1] = { lhs = lhs, mode = mode_string(g.modes), desc = g.desc }
      end
    end
  end

  local lines = {
    "Yap shortcuts (current buffer)",
    "Search with /, n and N; close with q or <Esc>.",
    "",
  }
  for _, row in ipairs(rows) do
    lines[#lines + 1] = string.format("%-18s %-5s %s", row.lhs, row.mode, row.desc)
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

--- Change the provider/model combo for the current buffer.
--- With an argument: "provider/model". Without: pick from `yap models`,
--- which discovers reachable providers from the backend settings and credentials.
function M.change_model(combo)
  if not combo then
    config.pick(function(choice)
      M.change_model(choice)
    end)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local provider, model = config.parse_combo(combo)
  if not provider then
    vim.notify("yap: expected provider/model, got: " .. combo, vim.log.levels.ERROR)
    return
  end
  vim.b[buf].yap_provider = provider
  vim.b[buf].yap_model = model
  frontmatter.sync(buf) -- persist: combo + used-models history live in the buffer
  -- A running turn adopts the new combo at its next model boundary; an idle
  -- buffer just uses it on the next send. The backend keeps native tool
  -- history intact, so no stop-and-resend is needed.
  local turn = running[buf]
  local proc = turn and turn.process
  if proc then
    local ok = pcall(function()
      proc:write(vim.json.encode({ type = "model", provider = provider, model = model }) .. "\n")
    end)
    if not ok then
      vim.notify("yap: could not switch model mid-turn (backend gone)", vim.log.levels.WARN)
    else
      state.model_switch[buf] = true
    end
  end
end

-- ─── Setup / composition root ─────────────────────────────────────────────

function M.setup(opts)
  opts = opts or {}
  -- Jail launchers (programs.yap.jail.modelGroups) forward an override as
  -- JSON; merge it over the setup() arguments so a jailed editor can pin
  -- different model groups (e.g. a public endpoint instead of a
  -- tailscale-only local model) without a second editor config.
  local env_groups = vim.env.YAP_MODEL_GROUPS
  if env_groups and env_groups ~= "" then
    local ok, decoded = pcall(vim.json.decode, env_groups)
    if ok and type(decoded) == "table" then
      opts.model_groups = vim.tbl_deep_extend("force", opts.model_groups or {}, decoded)
    end
  end
  if opts.nerd_font == false then
    M.config.icons = vim.tbl_extend("force", M.config.icons, {
      since = "",
      total = "",
      context = "◔",
      cache = "↻", -- plain-Unicode cache-reuse marker
      running = "▶",
      stopped = "⏹",
      error = "✗",
      waiting = "◉",
      idle = "○",
      done = "✓",
      steer = "⌁",
      queue = "↧",
      clear = "⌦",
      model_switch = "⇄",
      approval = "⚠", -- plain-Unicode backup for the shield_alert glyph
      fork = "⑂", -- plain-Unicode fork marker (OCR fork)
      cap_l = "[",
      cap_r = "]",
    })
  end
  for _, key in ipairs({ "provider", "model", "models" }) do
    assert(opts[key] == nil, "yap: " .. key .. " is no longer a setup option; configure model_groups instead")
  end
  for _, role in ipairs({ "editor", "title" }) do
    assert(
      not (opts.model_groups and opts.model_groups[role] ~= nil),
      "yap: model_groups." .. role .. " was replaced by model_groups.flash"
    )
  end
  local merged = vim.tbl_deep_extend("force", M.config, opts)
  for _, role in ipairs({ "agent", "flash" }) do
    local combo = merged.model_groups[role]
    assert(
      type(combo) == "string" and (role == "flash" and combo == "" or config.parse_combo(combo)),
      "yap: model_groups." .. role .. " must be a provider/model combo" .. (role == "flash" and " or empty" or "")
    )
  end
  M.config = merged
  config.load_models_cache()
  config.refresh_models()
  -- Resolve every data path — defaults included — against the real home
  -- directory (R-data-paths): a relative or unset $HOME must never make yap
  -- read or write inside the project. `~` expands; a relative override is
  -- refused by paths.expand rather than silently resolved against the cwd.
  for _, key in ipairs({ "agents_file", "templates_dir", "skills_dir", "agents_dir", "sessions_dir" }) do
    local v = M.config[key]
    if type(v) == "string" and v ~= "" then
      M.config[key] = paths.expand(v)
    end
  end
  -- Propagate the (possibly overridden) data root to the path resolver.
  paths.dirs.sessions_dir = M.config.sessions_dir

  -- Configured sessions and guard mappings are global: they act on state
  -- shared by every buffer, so they must work from any file. The other
  -- keymaps act on the current buffer and stay buffer-local in setup_buffer.
  if M.config.keymaps.sessions ~= "" then
    vim.keymap.set("n", M.config.keymaps.sessions, function()
      M.sessions()
    end, { silent = true, desc = "yap: sessions" })
  end
  if M.config.keymaps.sessions_all ~= "" then
    vim.keymap.set("n", M.config.keymaps.sessions_all, function()
      M.sessions("all")
    end, { silent = true, desc = "yap: sessions (all projects)" })
  end
  if M.config.keymaps.guard ~= "" then
    vim.keymap.set("n", M.config.keymaps.guard, function()
      guard.toggle()
    end, { silent = true, desc = "yap: guard board" })
  end

  -- Direct file/explorer opens adopt the same file-backed session.
  local adopt_group = vim.api.nvim_create_augroup("YapAdopt", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = adopt_group,
    callback = function(args)
      stream.forget(args.buf)
      if vim.b[args.buf].yap_scratch and vim.api.nvim_buf_is_valid(vim.b[args.buf].yap_scratch) then
        vim.b[vim.b[args.buf].yap_scratch].yap_queue_armed = false
        vim.b[vim.b[args.buf].yap_scratch].yap_queue_dispatch = false
      end
      state.steer[args.buf] = nil
      state.model_switch[args.buf] = nil
      state.clear_queued[args.buf] = nil
      pending_approvals[args.buf] = nil
      state.last_tool_call[args.buf] = nil
      state.tool_call_counts[args.buf] = nil
      -- Release the per-buffer UI state so the winbar's rollup and cache
      -- don't iterate/retain entries for buffers that are gone.
      live[args.buf] = nil
      state.live_usage[args.buf] = nil
      state.sessions[args.buf] = nil
      errors[args.buf] = nil
      state.error_code[args.buf] = nil
      last_turn[args.buf] = nil
      awaiting[args.buf] = nil
      stopped[args.buf] = nil
      describe.forget(args.buf)
      audit.forget(args.buf)
      winbar.clear_desc(args.buf)
    end,
  })
  -- Persist a session as soon as it leaves every window, so the file on disk
  -- never trails the in-memory buffer. Neovim reloads an unmodified,
  -- file-backed buffer from disk when it is re-entered; if that file is
  -- stale (text typed but not yet saved), the reload silently drops the
  -- in-memory text. Saving on hide keeps the file current, so any
  -- reload/`:edit`/reopen is lossless. Only session buffers are saved —
  -- the live tool tail and scratch queue have no yap_path.
  vim.api.nvim_create_autocmd("BufHidden", {
    group = adopt_group,
    callback = function(args)
      local buf = args.buf
      if vim.b[buf].yap and vim.b[buf].yap_path then
        session.save(buf)
      end
    end,
  })
  -- A session's in-memory buffer is the source of truth: the file is only a
  -- serialization and can trail the buffer (or be written by another
  -- instance). When Neovim detects the file changed outside the buffer, keep
  -- the buffer and suppress the "file has changed" prompt/reload — the next
  -- save re-serializes whatever is in memory.
  vim.api.nvim_create_autocmd("FileChangedShell", {
    group = adopt_group,
    callback = function(args)
      local buf = args.buf
      if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].yap then
        vim.v.fcs_choice = ""
      end
    end,
  })
  -- Native listed-buffer replacement handles navigation after deletion.
  vim.api.nvim_create_autocmd("BufUnload", {
    group = adopt_group,
    callback = function(args)
      local buf = args.buf
      if vim.b[buf].yap then
        vim.b[buf].yap_resume_pending = true
        subagent.close_children(buf)
        M.stop(buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = adopt_group,
    callback = function()
      for _, process in pairs(servers) do
        process:kill(15)
      end
    end,
  })
  -- A transcript opened from outside the sessions root is adopted when it is
  -- recognisably yap-shaped: yap frontmatter (provider+model) or a `# @system`
  -- heading. Ordinary markdown stays ordinary.
  local function is_yap_shaped(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 200, false)
    if lines[1] and lines[1]:match("^%-%-%-%s*$") then
      local has_provider, has_model = false, false
      for i = 2, #lines do
        if lines[i]:match("^%-%-%-%s*$") then
          return has_provider and has_model
        end
        if lines[i]:match("^provider:%s*%S") then
          has_provider = true
        end
        if lines[i]:match("^model:%s*%S") then
          has_model = true
        end
      end
      return false -- unterminated frontmatter within the first 200 lines
    end
    for _, l in ipairs(lines) do
      if l:match("^# @system%s*$") then
        return true
      end
    end
    return false
  end

  local function is_session_path(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    local root = paths.sessions_root()
    -- Only the session transcript is a session: the sidecar files in the
    -- same directory (notes.md and audit.jsonl) must never be adopted, or
    -- the scratch buffer becomes a session (its own winbar, its own <C-s>
    -- send, a rollup entry) instead of dispatching to its owner. The
    -- transcript is any `.md` file except the notes.md sidecar: it is
    -- usually `session.md`, but is renamed to set the session title.
    local base = vim.fn.fnamemodify(name, ":t")
    if base == "" or base == "notes.md" or not base:match("%.md$") then
      return name, false
    end
    if name:sub(1, #root + 1) == root .. "/" then
      return name, true
    end
    return name, is_yap_shaped(buf)
  end
  vim.api.nvim_create_autocmd("BufAdd", {
    group = adopt_group,
    callback = function(args)
      -- :badd must not promote an already managed agent into workspace navigation.
      if vim.b[args.buf].yap and require("harness.ui.picker").agent(nil, args.buf) then
        vim.bo[args.buf].buflisted = false
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = adopt_group,
    callback = function(args)
      local name, session_path = is_session_path(args.buf)
      if session_path then
        buffers.adopt(args.buf, name)
      end
    end,
  })
  -- A `:file`/`:saveas` rename sets the transcript filename, which is the
  -- session title. Commit that basename within the session directory once,
  -- when Neovim reports the rename; routine saves must not call set_name,
  -- since doing so resets the alternate-buffer tracking used by :bd.
  -- |:YapFork| copies the conversation into a new directory.
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = adopt_group,
    callback = function(args)
      local buf = args.buf
      if not vim.b[buf].yap then
        return
      end
      local path, previous = session.reconcile_name(buf)
      if previous then
        if vim.fn.filereadable(path) == 0 then
          session.save(buf, previous)
        elseif vim.fn.filereadable(previous) == 1 then
          vim.fn.delete(previous)
        end
        lsp.attach(buf)
      end
    end,
  })
  -- The winbar degrades with window width (see render_winbar); re-evaluate
  -- its `%!` expression whenever a window is resized.
  vim.api.nvim_create_autocmd("WinResized", {
    group = adopt_group,
    callback = function()
      util.redraw_status()
    end,
  })
  -- Adopt sessions that were loaded before setup (lazy plugin loading).
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name, session_path = is_session_path(b)
    if session_path and vim.api.nvim_buf_is_loaded(b) then
      buffers.adopt(b, name)
    end
  end

  -- Session buffers carry only the yap language server (symbols, completion,
  -- diagnostics). Any other client that attaches is detached buffer-locally,
  -- so a shared markdown server keeps serving ordinary files while its
  -- semantic-token/inlay-hint stream stays off the large session buffer.
  local group = vim.api.nvim_create_augroup("YapLsp", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      if not (vim.b[args.buf].yap or vim.b[args.buf].yap_scratch_notes) then
        return
      end
      local id = args.data and args.data.client_id
      if not id then
        return
      end
      if lsp.is_yap_client(id) then
        -- Only Yap buffers get automatic popups; the server advertises @, #,
        -- : and - and returns items only in file, role or frontmatter contexts.
        if M.config.builtin_completion then
          vim.lsp.completion.enable(true, id, args.buf, {
            autotrigger = true,
            convert = function(item)
              -- Native completion can use filterText as the inserted word
              -- when the path itself does not start with the query.
              if item.kind == vim.lsp.protocol.CompletionItemKind.File and item.textEdit then
                return { word = item.textEdit.newText }
              end
              return {}
            end,
          })
        end
        return
      end
      -- Detach after LspAttach completes: Neovim 0.13's Client:on_attach()
      -- re-adds the buffer to attached_buffers *after* firing LspAttach, so a
      -- synchronous detach here is silently undone and a foreign markdown
      -- server (markdown_oxide) keeps answering documentSymbol, shadowing the
      -- yap outline with its all-"struct" headings and racing mini.pick.
      vim.schedule(function()
        pcall(vim.lsp.buf_detach_client, args.buf, id)
      end)
    end,
  })
  -- Punctuation triggers do not cover a partially typed frontmatter key or
  -- resume a file query after the native menu was dismissed.
  local file_retry = 0
  vim.api.nvim_create_autocmd({ "CompleteDone", "InsertLeave" }, {
    group = group,
    callback = function(args)
      if args.event == "InsertLeave" or vim.v.event.reason == "cancel" then
        file_retry = file_retry + 1
      end
    end,
  })
  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = group,
    callback = function(args)
      if not (vim.b[args.buf].yap or vim.b[args.buf].yap_scratch_notes) then
        return
      end
      if not M.config.builtin_completion then
        return
      end
      file_retry = file_retry + 1
      local char = vim.v.char
      if not char:match("^[a-zA-Z0-9_./%-]$") then
        return
      end
      local win = vim.api.nvim_get_current_win()
      local cursor = vim.api.nvim_win_get_cursor(win)
      local row, col = cursor[1], cursor[2]
      local line = vim.api.nvim_get_current_line()
      local prefix = line:sub(1, col) .. char
      -- Match the server's token boundary: @ must start the line or follow
      -- a space or tab. A closing popup alone never schedules a retry.
      local token = prefix:match("^(@[a-zA-Z0-9_./%-]+)$") or prefix:match("[ \t](@[a-zA-Z0-9_./%-]+)$")
      local heading = (prefix .. line:sub(col + 1)):match("^# @[a-zA-Z]*$")
      if token and #token >= 3 and not heading and vim.fn.pumvisible() == 0 then
        local retry = file_retry
        vim.defer_fn(function()
          if
            retry ~= file_retry
            or not M.config.builtin_completion
            or vim.api.nvim_get_current_win() ~= win
            or vim.api.nvim_get_current_buf() ~= args.buf
            or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i"
            or vim.fn.pumvisible() ~= 0
          then
            return
          end
          local pos = vim.api.nvim_win_get_cursor(win)
          if pos[1] ~= row or pos[2] ~= #prefix or vim.api.nvim_get_current_line():sub(1, pos[2]) ~= prefix then
            return
          end
          local client = vim.lsp.get_clients({ bufnr = args.buf, name = "yap" })[1]
          if client and lsp.is_yap_client(client.id) then
            vim.lsp.completion.get({ client_id = client.id })
          end
        end, 100)
        return
      end
      if not vim.b[args.buf].yap or not char:match("^[a-z_]$") then
        return
      end
      -- A frontmatter key only: the cursor sits between the opening `---` and
      -- the closing `---`. end_line() is a bounded 200-line read; the old
      -- scan read line 2 through the cursor and searched for `---` on every
      -- [a-z_] keystroke, so typing in a large transcript paid O(cursor depth).
      local e = frontmatter.end_line(args.buf)
      if not e or row < 2 or row >= e then
        return
      end
      if not prefix:match("^[a-z_]+$") or line:find(":", 1, true) then
        return
      end
      local client = vim.lsp.get_clients({ bufnr = args.buf, name = "yap" })[1]
      if not client or not lsp.is_yap_client(client.id) then
        return
      end
      vim.schedule(function()
        if
          vim.api.nvim_get_current_buf() == args.buf
          and vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
          and vim.api.nvim_win_get_cursor(0)[1] == row
        then
          vim.lsp.completion.get({ client_id = client.id })
        end
      end)
    end,
  })
  -- Completion of @path references follows the live project directory, so
  -- refresh the server's context when :cd moves the working directory.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      for buf in pairs(state.sessions) do
        if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].yap then
          lsp.notify_context(buf)
        end
      end
    end,
  })

  -- Turn completion is a first-class event: User YapTurnDone fires per
  -- buffer when a send finishes. The default handler is the herdr-style
  -- "it's waiting for you" toast, but any user autocmd can hook the
  -- same event — noice/nf-notify rendering, chaining a next send, etc.
  -- Announce a completed conversation only when it is not visible in any
  -- window. A delegated child reports to its running parent instead.
  local notify_group = vim.api.nvim_create_augroup("YapTurn", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = notify_group,
    pattern = "YapTurnDone",
    callback = function(args)
      local data = args.data or {}
      if not M.config.notify_done then
        return
      end
      -- The error path already notified (R-error-surface); don't double up.
      local parent = vim.b[data.buf].yap_subagent_parent
      if errors[data.buf] or (parent and running[parent]) then
        return
      end
      -- The session is being closed by a tool call, so there is no waiting
      -- session to announce when this turn finishes.
      if data.close_requested then
        return
      end
      -- No toast if the user can already see the stream in another window.
      if vim.fn.win_findbuf(data.buf)[1] then
        return
      end
      local title = session.live_label(data.buf)
      local msg = ("yap: %s %s"):format(title, M.config.icons.waiting)
      vim.notify(msg, vim.log.levels.INFO, { title = "yap" })
    end,
  })

  -- Session buffers are coloured by Vim's markdown syntax, not the
  -- treesitter highlighter, whose per-redraw range spans every folded row and
  -- so grows with session size. See session/highlight.lua.
  require("harness.session.highlight").setup()

  -- Start the yap language server now rather than when the first session
  -- buffer opens, so its spawn and initialize handshake overlap with the
  -- user's next keystrokes instead of the first symbol request. Scheduled so
  -- setup() never blocks; a missing binary just leaves the client unmade.
  vim.schedule(function()
    lsp.ensure()
  end)
end

return M
