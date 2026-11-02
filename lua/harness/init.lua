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
M.open = buffers.open
M.adopt = buffers.adopt

-- Session listing and navigation (sessions).
M.sessions = sessions.sessions
M.instances = sessions.instances
M.buffers = buffers.pick
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
function M.insert_file(opts)
  return template.insert_file(opts)
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

-- ─── Shared per-buffer state aliases (for the autocmds below) ─────────────

local running = state.running
local stopped = state.stopped
local live = state.live
local errors = state.errors
local last_turn = state.last_turn
local awaiting = state.awaiting
local servers = state.servers
local pending_approvals = state.pending_approvals
local close_after_turn = state.close_after_turn
local stream_flush = state.stream_flush
local follow_override = state.follow_override

-- Close the session's drawers. `scratch`/`tail_buf` are the drawer buffers
-- captured while `buf` was still loaded: :bd unloads the session before a
-- deferred callback runs, clearing vim.b[buf].yap_scratch, so the callback
-- must not re-read it from the buffer.
local function close_session_drawers(buf, scratch, tail_buf)
  if not scratch and vim.api.nvim_buf_is_valid(buf) then
    scratch = vim.b[buf].yap_scratch
  end
  if scratch and vim.api.nvim_buf_is_valid(scratch) then
    drawer.close(scratch, buf)
  end
  if not tail_buf then
    local t = audit.view(buf)
    tail_buf = t and t.bufnr
  end
  if tail_buf and vim.api.nvim_buf_is_valid(tail_buf) then
    drawer.close(tail_buf, buf)
  end
end

-- ─── User commands kept here (small, self-contained) ─────────────────────

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
  local proc = running[buf]
  if proc then
    local ok = pcall(function()
      proc:write(vim.json.encode({ type = "model", provider = provider, model = model }) .. "\n")
    end)
    if not ok then
      vim.notify("yap: could not switch model mid-turn (backend gone)", vim.log.levels.WARN)
    end
  end
end

-- ─── Setup / composition root ─────────────────────────────────────────────

function M.setup(opts)
  opts = opts or {}
  if opts.nerd_font == false then
    M.config.icons = vim.tbl_extend("force", M.config.icons, {
      since = "",
      total = "",
      running = "▶",
      stopped = "⏹",
      error = "✗",
      waiting = "◉",
      idle = "○",
      done = "✓",
      steer = "⌁",
      queue = "↧",
      approval = "⚠", -- plain-Unicode backup for the shield_alert glyph
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
      local process = servers[args.buf]
      if process then
        process:kill(15)
      end
      servers[args.buf] = nil
      if vim.b[args.buf].yap_scratch and vim.api.nvim_buf_is_valid(vim.b[args.buf].yap_scratch) then
        vim.b[vim.b[args.buf].yap_scratch].yap_queue_armed = false
        vim.b[vim.b[args.buf].yap_scratch].yap_queue_dispatch = false
      end
      state.steer[args.buf] = nil
      running[args.buf] = nil
      pending_approvals[args.buf] = nil
      stream_flush[args.buf] = nil
      follow_override[args.buf] = nil
      close_after_turn[args.buf] = nil
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
      winbar.clear_desc(args.buf)
      fold.clear_text(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = adopt_group,
    callback = function(args)
      local buf = args.buf
      if not vim.b[buf].yap then
        return
      end
      -- Capture the drawer buffers now: :bd unloads the session before the
      -- deferred check below runs, clearing vim.b[buf].yap_scratch. The tail
      -- viewer already survives via the module table, but capture it too.
      local scratch = vim.b[buf].yap_scratch
      local t = audit.view(buf)
      local tail_buf = t and t.bufnr
      -- Let window/buffer transitions settle; focusing a drawer alone must
      -- not close it while the session remains displayed in another window.
      vim.schedule(function()
        if #vim.fn.win_findbuf(buf) == 0 then
          close_session_drawers(buf, scratch, tail_buf)
        end
      end)
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
  local function is_session_path(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    local root = paths.sessions_root()
    -- Only the session transcript is a session: the sidecar files in the
    -- same directory (notes.md and audit.jsonl) must never be adopted, or
    -- the scratch jotter becomes a session (its own winbar, its own <C-s>
    -- send, a rollup entry) instead of dispatching to its owner. The
    -- transcript is any `.md` file except the notes.md sidecar: it is
    -- usually `session.md`, but is renamed to set the session title.
    local base = vim.fn.fnamemodify(name, ":t")
    return name, name:sub(1, #root + 1) == root .. "/" and base:match("%.md$") ~= nil and base ~= "notes.md"
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
      vim.cmd.redrawstatus()
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
          vim.lsp.completion.enable(true, id, args.buf, { autotrigger = true })
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
  -- Punctuation triggers do not cover a partially typed frontmatter key.
  -- Ask for completion only while typing a key, never in message prose.
  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = group,
    callback = function(args)
      if not (vim.b[args.buf].yap or vim.b[args.buf].yap_scratch_notes) then
        return
      end
      if not M.config.builtin_completion then
        return
      end
      local char = vim.v.char
      if not char:match("^[a-z_]$") then
        return
      end
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row, col = cursor[1], cursor[2]
      if row < 2 or vim.api.nvim_buf_get_lines(args.buf, 0, 1, false)[1] ~= "---" then
        return
      end
      local lines = vim.api.nvim_buf_get_lines(args.buf, 1, row, false)
      for i = 1, #lines - 1 do
        if lines[i] == "---" then
          return
        end
      end
      local line = lines[#lines]
      if not line or not (line:sub(1, col) .. char):match("^[a-z_]+$") or line:find(":", 1, true) then
        return
      end
      local client = vim.lsp.get_clients({ bufnr = args.buf, name = "yap" })[1]
      if not client or not lsp.is_yap_client(client.id) then
        return
      end
      vim.schedule(function()
        if vim.api.nvim_get_current_buf() == args.buf and vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
          and vim.api.nvim_win_get_cursor(0)[1] == row then
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
      if close_after_turn[data.buf] then
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
