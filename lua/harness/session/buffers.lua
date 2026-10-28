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

local function setup_buffer(buf)
  -- Mark the buffer as a yap conversation BEFORE the filetype triggers the
  -- LSP's FileType autocommand, so the LspAttach guard in M.setup can see it.
  -- A session buffer is not code: markdown LSPs (semantic tokens, inlay hints)
  -- add per-redraw cost on a large session and buy nothing (R-buffer-only-state).
  vim.b[buf].yap = true
  state.sessions[buf] = true
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
    harness().stop()
  end, "yap: stop in-flight request")
  map("n", keys.change_model, function()
    harness().change_model()
  end, "yap: change model")
  map("n", keys.live, function()
    harness().live()
  end, "yap: live tool output")
  map("n", keys.scratch, function()
    harness().scratch_toggle()
  end, "yap: toggle scratch")
  map("n", keys.insert, function()
    harness().insert()
  end, "yap: insert template or skill")
  map("i", keys.insert, function()
    vim.cmd.stopinsert()
    harness().insert()
  end, "yap: insert template or skill")
  map("i", keys.insert_file, function()
    harness().insert_file({ from_insert = true })
  end, "yap: insert file reference")
  map("n", keys.help, function()
    harness().show_keymaps(buf)
  end, "yap: show shortcuts")
  require("harness.ui.fold").setup_buffer(buf, keys)
  require("harness.ui.textobj").setup_buffer(buf, keys)

  -- Self-evaluating winbar: a pure function of buffer state, refreshed
  -- by Neovim on every redraw.
  vim.wo.winbar = "%!v:lua.require'harness'.winbar()"
end

--- Open a new yap session buffer.
function M.new(opts)
  opts = opts or {}
  local win = vim.api.nvim_get_current_win()
  local previous = vim.api.nvim_win_get_buf(win)
  -- `enew` (and the hidden case's closing nvim_win_set_buf) switches this
  -- window's buffer, which E1513 forbids while 'winfixbuf' is set — a
  -- mini.files explorer window pins its buffer. Clear it for the span of
  -- this function and restore it so a pinned window stays pinned.
  local fixed = vim.wo[win].winfixbuf
  local cursorline = vim.wo[win].cursorline
  vim.wo[win].winfixbuf = false
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
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
    vim.b[buf].yap_path = opts.path
    vim.api.nvim_buf_set_name(buf, opts.path)
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
  session.save(buf)
  -- Create the session's live tool tail now (empty until a tool runs), before
  -- any :file rename or tool run.
  audit.ensure(buf)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })

  setup_buffer(buf)
  if opts.hidden then
    vim.api.nvim_win_set_buf(win, previous)
    vim.wo[win].cursorline = cursorline
  end
  vim.wo[win].winfixbuf = fixed

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
  vim.b[buf].yap_project_cwd = paths.project_cwd(path)
  -- Resume the recorded combo from frontmatter. Nothing is injected on
  -- open — adopt only reads, so resuming never dirties the buffer.
  local e = frontmatter.end_line(buf)
  if e then
    local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
    if fm and fm.provider and fm.provider ~= "" and fm.model and fm.model ~= "" then
      vim.b[buf].yap_provider = fm.provider
      vim.b[buf].yap_model = fm.model
    end
    if fm and fm.tools then
      vim.b[buf].yap_tools = fm.tools
    end
    if fm and fm.agent then
      vim.b[buf].yap_agent = fm.agent
    end
  end
  -- A reopened session that ended on `# @user` awaits the next reply;
  -- seed the overview hint so it counts before its first send here.
  winbar.seed_awaiting(buf)
  setup_buffer(buf)
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

--- Display only: the real filename remains available to :write and explorers.
function M.label(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.b[buf].yap then
    return nil
  end
  local title = session.live_label(buf)
  local duplicate = false
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= buf and vim.bo[other].buflisted and vim.b[other].yap and session.live_label(other) == title then
      duplicate = true
      break
    end
  end
  return picker.status(buf)
    .. " "
    .. title
    .. (duplicate and (" [" .. buf .. "]") or "")
end

--- The ordinary MiniPick buffer list, with conversation labels instead of paths.
function M.pick()
  local pick = require("mini.pick")
  local items = {}
  -- Match the builtin buffer source's ordering and names, preserving bufnr
  -- for preview/selection rather than treating the display label as a filename.
  local output = vim.api.nvim_exec2("buffers", { output = true }).output
  for _, line in ipairs(vim.split(output, "\n")) do
    local buf = tonumber(line:match("^%s*(%d+)"))
    if buf then
      items[#items + 1] = { bufnr = buf, text = M.label(buf) or line:match('"(.*)"') }
    end
  end
  return pick.start({
    source = {
      name = "Buffers",
      items = items,
      show = function(buf, entries, query)
        local rendered = {}
        local ns = vim.api.nvim_create_namespace("yap.buffer_labels")
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        local highlights = {}
        local has_icons, icons = pcall(require, "mini.icons")
        for i, item in ipairs(entries) do
          local entry = vim.tbl_extend("force", {}, item)
          local icon, hl = " ", "Normal"
          if has_icons then
            local ft = vim.bo[item.bufnr].filetype
            if ft == "man" then
              -- man:// URIs have no "file" entry; the filetype does.
              icon, hl = icons.get("filetype", "man")
            else
              -- "file" resolves a terminal's shell (term://…/zsh -> the zsh
              -- glyph), ssh configs, and ordinary paths by extension/filetype.
              icon, hl = icons.get("file", vim.api.nvim_buf_get_name(item.bufnr))
            end
          end
          entry.text = icon .. " " .. item.text
          rendered[i] = entry
          highlights[i] = { width = #icon, hl = hl, prefix = #icon + 1 }
        end
        pick.default_show(buf, rendered, query)
        local colors = {
          running = "DiagnosticInfo",
          error = "DiagnosticError",
          stopped = "DiagnosticWarn",
          waiting = "DiagnosticHint",
          approval = "DiagnosticWarn",
          done = "Comment",
          idle = "Comment",
        }
        for i, item in ipairs(entries) do
          local h = highlights[i]
          vim.api.nvim_buf_add_highlight(buf, ns, h.hl, i - 1, 0, h.width)
          if vim.b[item.bufnr].yap then
            local glyph = picker.status(item.bufnr)
            local status = state.pending_approvals[item.bufnr] and "approval"
              or picker.state(item.bufnr)
            vim.api.nvim_buf_add_highlight(buf, ns, colors[status], i - 1, h.prefix, h.prefix + #glyph)
          end
        end
      end,
    },
  })
end

-- Reachable from the facade/setup and from sessions.lua (focus_buf).
M.switch_buf = switch_buf
M.focus_buf = focus_buf

return M
