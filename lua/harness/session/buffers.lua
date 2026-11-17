-- Session buffer lifecycle: create, open, adopt, fork, focus and teardown.
--
-- Conversations are listed, file-backed buffers. Delegated agents remain
-- unlisted and are reachable through the session tree.

local M = {}

local state = require("harness.state")
local config = require("harness.config")
local frontmatter = require("harness.model.frontmatter")
local audit = require("harness.client.audit")
local winbar = require("harness.ui.winbar")
local fold = require("harness.ui.fold")
local textobj = require("harness.ui.textobj")
local paths = require("harness.path")
local session = require("harness.session")
local system = require("harness.client.system")
local lsp = require("harness.client.lsp")
local picker = require("harness.ui.picker")

local running = state.running

local function harness()
  return require("harness")
end

--- Expand a frontmatter-recorded directory: `~` against $HOME, else normalize.
--- Tolerant of hand-edited relative values (normalize leaves them relative).
local function expand_home(p)
  if p:sub(1, 1) == "~" then
    return vim.fs.normalize(vim.env.HOME .. p:sub(2))
  end
  return vim.fs.normalize(p)
end

local function setup_buffer(buf)
  -- Mark the buffer as a yap conversation BEFORE the filetype triggers the
  -- LSP's FileType autocommand, so the LspAttach guard in M.setup can see it.
  -- A session buffer is not code: markdown LSPs (semantic tokens, inlay hints)
  -- add per-redraw cost on a large session and buy nothing (R-buffer-only-state).
  vim.b[buf].yap = true
  state.sessions[buf] = true
  -- Native :write uses the session save path, including pending :file renames.
  -- An explicit target (`:w /somewhere/else.md`) is the user moving the
  -- transcript: the session adopts the new path (data_dir tie stays put),
  -- rather than silently ignoring the command and writing to the old one.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function(ev)
      local target = ev.file
      if target and target ~= "" and target ~= (vim.b[buf].yap_path or "") then
        target = vim.fn.fnamemodify(target, ":p")
        if target:match("%.md$") then
          vim.b[buf].yap_path = target
          pcall(vim.api.nvim_buf_set_name, buf, target)
          require("harness.client.lsp").attach(buf)
        end
      end
      session.save(buf)
    end,
  })
  -- Opening a saved session (:edit) sets the filetype before setup_buffer
  -- runs, so a markdown client may already be attached; detach it from this
  -- buffer (buffer-locally, so a shared server keeps serving other files).
  -- The yap client is the exception: it is re-attached below.
  if vim.lsp and vim.lsp.get_clients then
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
      if not lsp.is_yap_client(client.id) then
        pcall(vim.lsp.buf_detach_client, buf, client.id)
      end
    end
  end
  lsp.attach(buf)

  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide"
  -- Keep agents in the session tree, not the ordinary workspace list.
  vim.bo[buf].buflisted = not picker.agent(nil, buf)
  vim.b[buf].minidiff_disable = true

  -- Read-only drawers enable cursorline. Their windows are reusable (:e and
  -- session picker), so clear that window-local option on session entry.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      vim.wo.cursorline = false
    end,
  })
  if vim.api.nvim_get_current_buf() == buf then
    vim.wo.cursorline = false
  end

  -- Apply the highlight policy (markdown syntax instead of the treesitter
  -- highlighter). Applied here as well as deferred below: setting 'filetype'
  -- above has already run the FileType autocommands synchronously, so this pass
  -- cannot be lost if the scheduled one is dropped.
  require("harness.session.highlight").apply(buf)
  -- Deferred so a FileType handler that starts the highlighter later is also
  -- stopped: ftplugin/markdown.lua starts it, and the policy keeps the parser
  -- (touchup reads the tree) while stopping the highlighter.
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    require("harness.session.highlight").apply(buf)
  end)

  local keys = harness().config.keymaps
  local map = function(mode, lhs, rhs, desc)
    if lhs == "" then
      return
    end
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  map("n", keys.send, harness().send, "yap: send")
  map("i", keys.send, function()
    vim.cmd.stopinsert()
    harness().send()
  end, "yap: send")
  map("n", keys.stop, function()
    harness().stop(buf, { focus = true })
  end, "yap: stop in-flight request")
  map("n", keys.change_model, function()
    harness().change_model()
  end, "yap: change model")
  map("n", keys.live, function()
    harness().live()
  end, "yap: live tool output")
  map("n", keys.symbols, function()
    harness().symbols()
  end, "yap: symbols (newest first)")
  map("n", keys.scratch, function()
    harness().scratch_toggle()
  end, "yap: toggle scratch")
  map("n", keys.insert, function()
    harness().insert()
  end, "yap: insert template")
  map("i", keys.insert, function()
    vim.cmd.stopinsert()
    harness().insert()
  end, "yap: insert template")
  map("n", keys.help, function()
    harness().show_keymaps(buf)
  end, "yap: show shortcuts")
  require("harness.ui.fold").setup_buffer(buf, keys)
  require("harness.ui.textobj").setup_buffer(buf, keys)

  -- Self-evaluating winbar: a pure function of buffer state, refreshed
  -- by Neovim on every redraw. 'winbar' is window-local, so only set it when
  -- the buffer is already in the current window; a hidden buffer (a subagent,
  -- or :YapEval's session before its split opens) would otherwise stamp the
  -- yap bar onto whichever window happens to be current. The caller that
  -- shows the buffer sets it (see eval.lua and fork()).
  if vim.api.nvim_get_current_buf() == buf then
    vim.wo.winbar = "%!v:lua.require'harness'.winbar()"
  end
end

--- Open a new yap session buffer.
function M.new(opts)
  opts = opts or {}
  local win, fixed
  local buf
  if opts.hidden then
    -- A delegated agent is never shown in a window: create an unlisted,
    -- file-backed buffer directly and leave the focused window untouched.
    -- The old `:enew` + restore round-trip hijacked the window (the child
    -- flashed there) and could fail restoring the previous buffer once it
    -- had been unloaded/wiped in between ("Invalid buffer id").
    buf = vim.api.nvim_create_buf(false, false)
  else
    -- `enew` switches this window's buffer, which E1513 forbids while
    -- 'winfixbuf' is set — a mini.files explorer window pins its buffer.
    -- Clear it for the span of this function and restore it so a pinned
    -- window stays pinned.
    win = vim.api.nvim_get_current_win()
    fixed = vim.wo[win].winfixbuf
    vim.wo[win].winfixbuf = false
    vim.cmd("enew")
    buf = vim.api.nvim_get_current_buf()
  end
  if opts.system then
    vim.b[buf].yap_system = opts.system
  end
  if opts.agent then
    vim.b[buf].yap_agent = opts.agent
  end
  if opts.tools then
    vim.b[buf].yap_tools = opts.tools
  end
  if opts.path then
    -- Normalize so a relative path or `~` resolves against the project, never
    -- yap's data root; an already-absolute path passes through. The buffer is
    -- then file-backed at a stable location before the first save.
    local path = vim.fn.fnamemodify(opts.path, ":p")
    vim.b[buf].yap_path = path
    vim.api.nvim_buf_set_name(buf, path)
    -- A transcript outside yap's sessions root keeps its audit log and assets
    -- in a central data directory; one inside it keeps them beside it.
    -- Recorded in frontmatter so the .md can move anywhere and still find
    -- its sidecars.
    if paths.under_sessions_root(path) then
      vim.b[buf].yap_data_dir = vim.fn.fnamemodify(path, ":h")
    else
      vim.b[buf].yap_data_dir = paths.new_data_dir(vim.fn.getcwd())
    end
  end
  local provider, model = config.session_combo()
  vim.b[buf].yap_provider = opts.provider or provider
  vim.b[buf].yap_model = opts.model or model
  vim.b[buf].yap_project_cwd = vim.fs.normalize(vim.fn.getcwd())

  local lines = { "# @system", "" }
  vim.list_extend(lines, vim.split(vim.b[buf].yap_system or system.prompt(), "\n", { plain = true }))
  vim.list_extend(lines, { "", "# @user", "" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  frontmatter.sync(buf) -- prepend the session's model state (R-buffer-only-state: it lives in the buffer)
  -- Create the session file up front so the buffer is file-backed from
  -- the start: `:file` names the session immediately, before the first
  -- reply. The LSP guard in setup_buffer keeps markdown clients off it
  -- regardless of the .md extension.
  session.save(buf) -- assigns yap_data_dir for the chosen location
  frontmatter.sync(buf) -- record it (and the model state) in the transcript
  session.save(buf) -- write again so the file carries the frontmatter from day one
  require("harness.client.scratch").ensure_file(buf)
  -- Create the session's live tool tail now (empty until a tool runs), before
  -- any :file rename or tool run.
  audit.ensure(buf)
  if not opts.hidden then
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  end

  setup_buffer(buf)
  if not opts.hidden then
    vim.wo[win].winfixbuf = fixed
  end

  return buf
end

-- Subagent spawning and child teardown live in harness.client.subagent.

--- Open a saved session file as a yap buffer.
--- Turn a session-file buffer into a managed yap buffer: listed (except agents),
--- keymapped, live tool tail attached, model combo resumed from
--- frontmatter. Shared by sessions()/history() resume and by directly opening
--- a file under ~/.config/yap/sessions/.
local function adopt(buf, path)
  if vim.b[buf].yap then
    return buf
  end
  vim.b[buf].yap_path = path
  -- Resume durable per-session state from frontmatter. The originating cwd
  -- and data directory are recorded there. Inside the sessions root the
  -- sidecars sit beside the transcript, so the parent wins over the record —
  -- a directory rename keeps working. Outside it the recorded data_dir is
  -- the tie: the transcript may have been moved to any path and still finds
  -- its audit log and assets.
  local e = frontmatter.end_line(buf)
  local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false)) or nil
  local created_cwd = fm and fm.created_cwd
  vim.b[buf].yap_project_cwd =
    (created_cwd and created_cwd ~= "" and expand_home(created_cwd))
    or paths.project_cwd(path)
  if paths.under_sessions_root(path) then
    vim.b[buf].yap_data_dir = vim.fn.fnamemodify(path, ":h")
  elseif fm and fm.data_dir and fm.data_dir ~= "" then
    vim.b[buf].yap_data_dir = expand_home(fm.data_dir)
  end
  if fm then
    if fm.provider and fm.provider ~= "" and fm.model and fm.model ~= "" then
      vim.b[buf].yap_provider = fm.provider
      vim.b[buf].yap_model = fm.model
    end
    if fm.tools then
      vim.b[buf].yap_tools = fm.tools
    end
    if fm.agent then
      vim.b[buf].yap_agent = fm.agent
    end
  end
  -- A reopened session that ended on `# @user` awaits the next reply;
  -- seed the overview hint so it counts before its first send here.
  winbar.seed_awaiting(buf)
  winbar.seed_error(buf)
  setup_buffer(buf)
  require("harness.client.scratch").ensure_file(buf)
  audit.ensure(buf) -- the live tool tail (empty until a tool runs)
  audit.seed_session_usage(buf) -- durable all-time totals from the audit log
  return buf
end
M.adopt = adopt

--- Switch the current window's buffer, briefly clearing `winfixbuf` so a
--- window fixed to its buffer can still be redirected (E1513).
local function switch_buf(buf)
  local win = vim.api.nvim_get_current_win()
  local fixed = vim.wo[win].winfixbuf
  vim.wo[win].winfixbuf = false
  vim.api.nvim_set_current_buf(buf)
  vim.wo[win].winfixbuf = fixed
end

--- Focus an already-loaded buffer: jump to an existing window, otherwise
--- show it in the current one.
local function focus_buf(buf)
  local wins = vim.fn.win_findbuf(buf)
  if wins[1] then
    vim.api.nvim_set_current_win(wins[1])
  else
    switch_buf(buf)
  end
end

--- Load `path` into the current window, briefly clearing `winfixbuf` so a
--- window fixed to its buffer can still be redirected by `:edit` (E1513).
---
--- The read is forced to utf-8. A session file is UTF-8, but one stray byte
--- in it (a tool result that dumped binary) makes 'fileencodings' fall back to
--- latin1, and from then on every :write re-encodes the WHOLE transcript to
--- latin1 — one 0xBF per character outside latin1. Forcing the encoding on
--- read keeps writes utf-8 and repairs the stray byte to `?` instead.
local function edit_buf(path)
  local win = vim.api.nvim_get_current_win()
  local fixed = vim.wo[win].winfixbuf
  vim.wo[win].winfixbuf = false
  vim.cmd("edit ++enc=utf-8 " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  -- A lossy read (that stray byte became `?`) makes Vim mark the buffer
  -- 'readonly' to protect the file. Repairing it is the point here, and yap
  -- saves sessions with :write!, which would otherwise warn W10 on every save.
  -- A file that really is unwritable keeps its flag.
  if vim.bo[buf].readonly and vim.fn.filewritable(path) == 1 then
    vim.bo[buf].readonly = false
  end
  vim.wo[win].winfixbuf = fixed
end

--- Fork the in-memory transcript into an independent managed session. Keep
--- the source buffer (and any running process) attached to its original path.
--- bufload adopts the new file; switching buffers instead of :edit also works
--- when the source has unsaved edits (ordinary :edit would raise E37).
function M.fork(name)
  local source = vim.api.nvim_get_current_buf()
  if not vim.b[source].yap then
    return nil, ":YapFork only works in a yap session"
  end
  local path, err = session.fork(source, name, running[source] ~= nil)
  if not path then
    return nil, err
  end
  if not running[source] then
    session.save(source)
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  focus_buf(buf)
  adopt(buf, path)
  -- bufload may have adopted the fork while the source was still current;
  -- winbar is window/buffer-local, so set it on the now-visible fork too.
  vim.wo.winbar = "%!v:lua.require'harness'.winbar()"
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  return path
end

--- Open a saved session file as a yap buffer.
function M.open(path)
  local buf = vim.fn.bufnr(vim.fn.fnamemodify(path, ":p"))
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    -- The in-memory buffer is the source of truth: reuse it even when it is
    -- not flagged 'modified'. `:edit` would re-read the file from disk and
    -- discard text typed but not yet persisted — and 'modified' can be false
    -- while the buffer still holds such text (the flag does not capture every
    -- in-memory-vs-disk divergence a session can reach).
    focus_buf(buf)
    return adopt(buf, path)
  end
  edit_buf(path)
  return adopt(vim.api.nvim_get_current_buf(), path)
end

-- Reachable from the facade/setup and from sessions.lua (focus_buf).
M.switch_buf = switch_buf
M.focus_buf = focus_buf

return M
