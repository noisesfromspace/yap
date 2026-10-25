-- yap session persistence & picker.
--
-- A yap session is just the buffer's markdown written to a file — the
-- buffer IS the conversation, so the file is a lossless serialization.
-- Sessions live under ~/.config/yap/sessions/<cwd-slug>/ and are
-- autosaved after every completed reply. Pickers identify sessions by their
-- frontmatter `title` (always present, empty by default; a typed value wins)
-- or generated `description`;
-- unnamed sessions (no title or description) are hidden unless they have
-- subagents or hold an unsent `# @user` prompt (a scheduled prompt); open
-- sessions stay visible in the open-session picker via the filename fallback.
-- Saved subagents appear beneath their parent in history.

local view = require("harness.ui.view")

local M = {}

local frontmatter = require("harness.model.frontmatter")
local structure = require("harness.model.structure")
local paths = require("harness.path")
local picker = require("harness.ui.picker")

--- Write the buffer to its session file, creating one (named after the
--- current time) on first save. Also called when a buffer is opened so
--- the session is file-backed from the start. Renames the buffer to the
--- file so `:w` works as expected.
---
--- The write goes through `:write!` (not writefile()): the buffer then
--- OWNS the file in Neovim's eyes — mtime bookkeeping is set, so `:w`
--- keeps working and you never get E13 "file exists". `:write!` also
--- clears 'modified', so a clean buffer prompts nothing on exit; the
--- `[+]` flag is the real signal for "typed but not yet saved".
--- Writing without 'modified' is harmless.
--- Stamp `updated_at` and `turns` in the frontmatter immediately before
--- the buffer is written. This is the only place `updated_at` is set; every
--- other frontmatter rewrite preserves it, so the field means "last write".
--- `turns` (the count of `# @assistant` replies — completed turns, ignoring
--- the trailing empty `# @user` prompt) is recomputed here too so the picker
--- has an at-a-glance session depth without opening the file. One full-buffer
--- read feeds both the frontmatter parse and the turn count; the write
--- serializes the whole buffer anyway, so the extra scan is not new work.
--- The rewrite is skipped when neither field changed, or when the buffer
--- has no frontmatter to stamp.
local function stamp_updated_at(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if not lines[1] or not lines[1]:match("^%-%-%-%s*$") then
    return
  end
  local e
  for i = 2, #lines do
    if lines[i]:match("^%-%-%-%s*$") then
      e = i
      break
    end
  end
  if not e then
    return
  end
  local fm = frontmatter.parse(lines)
  if not fm then
    return
  end
  local turns = 0
  for i = e + 1, #lines do
    if lines[i]:match("^# @assistant%s*$") then
      turns = turns + 1
    end
  end
  local updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  if fm.updated_at == updated_at and fm.turns == turns then
    return -- unchanged: skip the rewrite so an untouched frontmatter stays clean
  end
  fm.updated_at, fm.turns = updated_at, turns
  vim.api.nvim_buf_set_lines(buf, 0, e, false, frontmatter.render(fm))
end

function M.save(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- A session buffer is a normal file-backed buffer; a nofile/scratch buffer
  -- carrying yap_path (e.g. a test fixture) cannot be :write'd and must be
  -- skipped rather than erroring E382.
  if vim.bo[buf].buftype ~= "" then
    return
  end
  local path = vim.b[buf].yap_path
  if not path then
    local dir = paths.session_dir(vim.fn.getcwd())
    paths.ensure_session_dir(dir)
    path = paths.new_session_path(dir)
    vim.b[buf].yap_path = path
    pcall(vim.api.nvim_buf_set_name, buf, path)
  end
  -- The session file is always <dir>/session.md, so re-point the buffer at
  -- its canonical file before writing: a `:file` rename moves the buffer's
  -- name, not the session file. This also stops a relative `:file` target
  -- from re-rooting the write into the cwd (and chmod'ing it 0700).
  local bufname = vim.api.nvim_buf_get_name(buf)
  if bufname ~= path and bufname ~= "" and not bufname:match("^%a+://") then
    pcall(vim.api.nvim_buf_set_name, buf, path)
  end
  stamp_updated_at(buf)
  paths.ensure_session_dir(vim.fn.fnamemodify(path, ":h"))
  -- Pre-create the file 0600: `:write!` would create it 0644 under the umask
  -- and only the chmod below would narrow it, leaving a fresh transcript
  -- briefly world-readable. An existing file keeps its own mode.
  if vim.uv.fs_stat(path) == nil then
    local fd = vim.uv.fs_open(path, "wx", 384) -- 0600
    if fd then
      vim.uv.fs_close(fd)
    end
  end
  local view = vim.api.nvim_get_current_buf() == buf and vim.fn.winsaveview() or nil
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent noautocmd keepjumps write!")
  end)
  -- The transcript routinely contains secrets (the model echoes config and
  -- keys into the conversation); keep it 0600 like the audit log. :write
  -- preserves the mode on later saves.
  vim.fn.setfperm(path, "rw-------")
  if view then
    vim.fn.winrestview(view)
  end
end

--- Copy the current in-memory transcript to a new session file. Do not rename
--- or save the source buffer: its process, tail viewer, and unsaved edits belong
--- to the original session. The caller opens the new file as a separate buffer.
--- An optional name is a basename; `.md` is added when omitted.
function M.fork(buf, name, running)
  local dir = paths.session_dir(vim.b[buf].yap_project_cwd or vim.fn.getcwd())
  local path
  if name and name ~= "" then
    if name == "." or name == ".." or name:find("[/\\]") then
      return nil, "fork name must be a filename, not a path"
    end
    if not name:match("%.md$") then
      name = name .. ".md"
    end
    path = paths.new_session_path(dir, name)
  else
    path = paths.new_session_path(dir)
  end
  paths.ensure_session_dir(dir)
  -- Exclusive creation prevents a named fork (or a rare generated-name
  -- collision) from replacing an existing session, even if it is empty.
  local fd, err = vim.uv.fs_open(path, "wx", 384) -- 0600
  if not fd then
    return nil, "cannot create fork: " .. err
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if running then
    -- send() has appended its in-progress # @assistant. Discard the
    -- current user/assistant pair and leave a fresh prompt.
    local current_assistant
    for i = #lines, 1, -1 do
      if lines[i] == "# @assistant" then
        current_assistant = i
        break
      end
    end
    if current_assistant then
      for i = current_assistant - 1, 1, -1 do
        if lines[i] == "# @user" then
          lines = vim.list_slice(lines, 1, i - 1)
          while lines[#lines] == "" do
            table.remove(lines)
          end
          vim.list_extend(lines, { "", "# @user", "" })
          break
        end
      end
    end
  end
  local fm = frontmatter.parse(lines)
  if fm then
    local ending
    for i = 2, #lines do
      if lines[i]:match("^%-%-%-%s*$") then
        ending = i
        break
      end
    end
    if ending then
      local created = os.date("!%Y-%m-%dT%H:%M:%SZ")
      local turns = 0
      for i = ending + 1, #lines do
        if lines[i] == "# @assistant" then
          turns = turns + 1
        end
      end
      local fork_fm = vim.tbl_extend("force", fm, {
        created_at = created,
        updated_at = created,
        turns = turns,
        forked_from = vim.b[buf].yap_path,
        forks = {},
      })
      fork_fm.subagent_parent = nil
      local block = frontmatter.render(fork_fm)
      vim.list_extend(block, vim.list_slice(lines, ending + 1))
      lines = block
    end
  end
  -- A self-contained session carries its dropped photos with it: copy the
  -- source's assets folder and re-point the `file://` references at the copy.
  local src_assets = paths.assets_dir(buf)
  if vim.uv.fs_stat(src_assets) then
    local dst_assets = vim.fn.fnamemodify(path, ":h") .. "/assets"
    paths.ensure_session_dir(dst_assets)
    local src_uri = vim.uri_from_fname(src_assets) .. "/"
    local dst_uri = vim.uri_from_fname(dst_assets) .. "/"
    for _, entry in ipairs(vim.fn.readdir(src_assets)) do
      local from = src_assets .. "/" .. entry
      local st = vim.uv.fs_stat(from)
      -- vim.fn.copy() is Vim's value-copy builtin and takes one argument;
      -- the filesystem copy is libuv's fs_copyfile.
      if st and st.type == "file" then
        local ok, copy_err = vim.uv.fs_copyfile(from, dst_assets .. "/" .. entry)
        if not ok then
          vim.uv.fs_close(fd)
          vim.fn.delete(path)
          return nil, "cannot copy fork asset: " .. tostring(copy_err)
        end
      end
    end
    for i, l in ipairs(lines) do
      lines[i] = l:gsub(vim.pesc(src_uri), function()
        return dst_uri
      end)
    end
  end
  local written, write_err = vim.uv.fs_write(fd, table.concat(lines, "\n") .. "\n", 0)
  vim.uv.fs_close(fd)
  if not written then
    vim.fn.delete(path)
    return nil, "cannot write fork: " .. write_err
  end
  -- A full transcript carries audit references and usage history. Copy the
  -- journal rather than moving it (as a buffer rename would): future turns
  -- in either session must never write into the other's audit log.
  local audit = paths.audit_path(buf)
  if vim.fn.filereadable(audit) == 1 then
    local dest = vim.fn.fnamemodify(path, ":h") .. "/audit.jsonl"
    paths.ensure_session_dir(vim.fn.fnamemodify(dest, ":h"))
    local copied, copy_err
    if running then
      local events, last_turn = {}, 0
      for _, line in ipairs(vim.fn.readfile(audit)) do
        events[#events + 1] = line
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" and ev.type == "turn_end" then
          last_turn = #events
        end
      end
      -- Pre-create 0600 so writefile() (which would create 0644) never leaves
      -- a brief world-readable window on a file holding full args/results.
      local fd = vim.uv.fs_open(dest, "wx", 384) -- 0600
      if fd then
        vim.uv.fs_close(fd)
      end
      copied, copy_err = pcall(vim.fn.writefile, vim.list_slice(events, 1, last_turn), dest)
    else
      copied, copy_err = vim.uv.fs_copyfile(audit, dest)
    end
    if not copied then
      vim.fn.delete(path)
      return nil, "cannot copy fork audit: " .. tostring(copy_err)
    end
    vim.fn.setfperm(dest, "rw-------") -- the copied journal holds the same secrets
  end
  -- A running source persists this link on its normal turn-end save.
  if fm then
    local source_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local source_fm = frontmatter.parse(source_lines)
    local forks = source_fm.forks or {}
    forks[#forks + 1] = path
    frontmatter.update(buf, { forks = forks })
  end
  return path
end
-- Message bodies come from the shared structural parser, so a `# @user`
-- quoted inside a fenced result (or inside a marker region) is content, not a
-- message boundary. `lines` may be a short slice read from a file.
local function first_message(lines, role)
  return structure.role_body(lines, role, false)
end

local function last_message(lines, role)
  return structure.role_body(lines, role, true)
end

--- True when the trailing `# @user` message holds an unsent prompt. `lines` is
--- the cheap 200-line slice list() reads for labels; a very long system
--- prompt can push the trailing prompt past that slice, so re-read the whole
--- file only in that truncated case. This is what makes a "scheduled" prompt
--- (typed, not yet sent) discoverable in the history picker.
local function has_pending_user_text(path, lines)
  if #last_message(lines, "user") > 0 then
    return true
  end
  if #lines == 200 then
    return #last_message(vim.fn.readfile(path), "user") > 0
  end
  return false
end

--- First task line for a subagent's stable picker identity, even after follow-ups.
function M.task(lines)
  for _, line in ipairs(first_message(lines, "user")) do
    if line:match("%S") then
      return line:gsub("^%s+", ""):gsub("%s+$", "")
    end
  end
end

-- The final user-facing answer, excluding display-only thinking, tool calls,
-- errors and other yap regions. An in-progress assistant turn with no answer
-- yet does not hide the last completed answer.
local function last_answer(lines)
  local scan = structure.scan_lines(lines)
  for h = #scan.headings, 1, -1 do
    local heading = scan.headings[h]
    if heading.role == "assistant" then
      local stop = scan.headings[h + 1] and scan.headings[h + 1].line - 1 or #lines
      local content = {}
      local region = 1
      local skipped_region = false
      for i = heading.line + 1, stop do
        while scan.regions[region] and (scan.regions[region].finish or #lines) < i do
          region = region + 1
        end
        local r = scan.regions[region]
        if (r and i >= r.start and i <= (r.finish or #lines))
          or lines[i]:match("^<!%-%- /?yap:") then
          while #content > 0 and content[#content]:match("^%s*$") do
            table.remove(content)
          end
          skipped_region = true
        elseif not (skipped_region and lines[i]:match("^%s*$")) then
          content[#content + 1] = lines[i]
          skipped_region = false
        end
      end
      while #content > 0 and content[1]:match("^%s*$") do
        table.remove(content, 1)
      end
      while #content > 0 and content[#content]:match("^%s*$") do
        table.remove(content)
      end
      if #content > 0 then
        return content
      end
    end
  end
  return {}
end

--- Markdown preview of a session: the initial `# @user` message followed by
--- the last `# @assistant` answer, rendered in a scratch buffer with the
--- `markdown` filetype so pickers show it with normal syntax highlighting
--- instead of flat text. Shared by the open-session and saved-session pickers so both
--- pickers preview the same two excerpts. Returns the |vim.ui.select()|
--- preview table `{ buf = ... }`.
function M.preview(lines)
  local content = {}
  local user = first_message(lines, "user")
  local assistant = last_answer(lines)
  if #user > 0 then
    content[#content + 1] = "## First message"
    content[#content + 1] = ""
    vim.list_extend(content, user)
  end
  if #assistant > 0 then
    if #content > 0 then
      content[#content + 1] = ""
      content[#content + 1] = "---"
    end
    content[#content + 1] = ""
    content[#content + 1] = "## Last answer"
    content[#content + 1] = ""
    vim.list_extend(content, assistant)
  end
  if #content == 0 then
    content = { "(no messages yet)" }
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  return { buf = buf, pos = { 1, 0 } }
end

--- The persisted directory name is a lossy cwd slug; this is deliberately a
--- best-effort display conversion for saved cross-project sessions.
local function slug_cwd(dir)
  return paths.slug_cwd(dir)
end

--- The first non-empty of title, description, then name — or nil when all
--- are empty. Shared by |M.label| and the winbar's session title, so the
--- title-wins-over-description precedence lives once.
function M.identity(title, description, name)
  return (title and title ~= "" and title)
    or (description and description ~= "" and description)
    or (name and name ~= "" and name)
    or nil
end

--- "agent · <identity>" for a subagent row. The identity is the first
--- non-empty of title, description, task, fallback and fallback_label, so
--- the open picker and the saved history list build the same chain.
function M.agent_label(agent, title, description, task, fallback, fallback_label)
  local identity = (title and title ~= "" and title)
    or (description and description ~= "" and description)
    or (task and task ~= "" and task)
    or (fallback and fallback ~= "" and fallback)
    or fallback_label
    or ""
  return agent .. " · " .. identity
end

--- Shared picker identity. A non-empty frontmatter `title` wins over the
--- generated `description`; otherwise the description wins, and the
--- directory name is only the final fallback. Project overviews prefix the
--- cwd so sessions from different worktrees are obvious.
function M.label(path, title, description, project_cwd)
  local name = path and path ~= "" and paths.session_name(path) or nil
  local identity = M.identity(title, description, name) or "session"
  return project_cwd and project_cwd ~= "" and (project_cwd .. "  " .. identity) or identity
end

--- List saved sessions. scope = "cwd" (default) or "all"
--- Items: { path, mtime, text, model, models? } sorted by parent recency;
--- `model`/`models` come from the session frontmatter.
function M.list(scope)
  local dirs
  if scope == "all" then
    dirs = {}
    for name, type in vim.fs.dir(paths.sessions_root()) do
      if type == "directory" then
        dirs[#dirs + 1] = vim.fs.joinpath(paths.sessions_root(), name)
      end
    end
  else
    dirs = { paths.session_dir(vim.fn.getcwd()) }
  end

  local items, children, owned_by = {}, {}, {}
  for _, dir in ipairs(dirs) do
    -- Sessions live one per directory: <dir>/<session>/session.md. The
    -- `*/session.md` glob skips dotfiles (hidden sessions are never listed)
    -- and avoids picking up the notes.md sidecar, which is also a .md file.
    for _, path in ipairs(vim.fn.glob(dir .. "/*/session.md", false, true)) do
      local name = paths.session_name(path)
      local lines = vim.fn.readfile(path, "", 200)
      local fm = frontmatter.parse(lines)
      local title = fm and fm.title or ""
      local description = fm and fm.description or ""
      local item = {
        path = path,
        mtime = vim.fn.getftime(path),
        text = M.label(path, title, description, scope == "all" and slug_cwd(dir) or nil),
        model = fm and fm.provider and fm.model and (fm.provider .. "/" .. fm.model) or nil,
        models = fm and #fm.models > 1 and fm.models or nil,
        turns = fm and fm.turns,
      }
      if fm and fm.agent then
        item.text = "↳ " .. M.agent_label(fm.agent, title, description, M.task(lines), nil, name)
        children[path] = item
      elseif fm and fm.forked_from then
        item.text = "↳ fork · " .. M.label(path, title, description)
        children[path] = item
        local owner = vim.fs.normalize(fm.forked_from)
        owned_by[owner] = owned_by[owner] or {}
        table.insert(owned_by[owner], vim.fs.normalize(path))
      elseif
        title ~= ""
        or description ~= ""
        or (fm and (#fm.subagents > 0 or fm.forked_from or #fm.forks > 0))
        or has_pending_user_text(path, lines)
      then
        items[#items + 1] = item
      end
      if fm then
        for _, child_path in ipairs(fm.subagents) do
          local owner = vim.fs.normalize(path)
          local child = vim.fs.normalize(child_path)
          owned_by[owner] = owned_by[owner] or {}
          table.insert(owned_by[owner], child)
        end
      end
    end
  end

  table.sort(items, function(a, b)
    return a.mtime > b.mtime
  end)
  local result, shown = {}, {}
  local owners = {}
  for _, paths_for_owner in pairs(owned_by) do
    local unique = {}
    for _, path in ipairs(paths_for_owner) do
      if not unique[path] then
        owners[path] = (owners[path] or 0) + 1
        unique[path] = true
      end
    end
  end
  local function add(item, depth, ancestors)
    if ancestors[item.path] then
      return -- malformed cycle in hand-edited frontmatter
    end
    shown[item.path] = true
    local row = vim.deepcopy(item)
    row.depth = depth
    if depth > 0 then
      row.text = string.rep("  ", depth) .. row.text
      if owners[vim.fs.normalize(item.path)] and owners[vim.fs.normalize(item.path)] > 1 and children[item.path] then
        row.text = row.text .. " [shared: " .. owners[vim.fs.normalize(item.path)] .. " branches]"
      end
    end
    result[#result + 1] = row
    local owned = {}
    local visited = {}
    for _, path in ipairs(owned_by[vim.fs.normalize(item.path)] or {}) do
      local child = children[path]
      if child and not visited[path] then
        owned[#owned + 1] = child
        visited[path] = true
      end
    end
    table.sort(owned, function(a, b)
      return a.mtime > b.mtime
    end)
    ancestors[item.path] = true
    for _, child in ipairs(owned) do
      add(child, depth + 1, ancestors)
    end
    ancestors[item.path] = nil
  end
  for _, item in ipairs(items) do
    add(item, 0, {})
  end
  -- Preserve discoverability when a parent is missing or excluded by scope.
  local orphans = {}
  for _, child in pairs(children) do
    if not shown[child.path] then
      orphans[#orphans + 1] = child
    end
  end
  table.sort(orphans, function(a, b)
    return a.mtime > b.mtime
  end)
  for _, child in ipairs(orphans) do
    if not shown[child.path] then
      local orphan = vim.deepcopy(child)
      orphan.text = orphan.text:sub(#"↳ " + 1) .. " (parent not shown)"
      if scope == "all" then
        orphan.text = slug_cwd(vim.fn.fnamemodify(orphan.path, ":h:h")) .. "  " .. orphan.text
      end
      add(orphan, 0, {})
    end
  end
  return result
end

local function preview_item(item)
  return M.preview(vim.fn.readfile(item.path))
end

--- Pick a session; on_choice(path) is called with the selected file.
function M.pick(opts, on_choice)
  opts = opts or {}
  local scope = opts.scope or "cwd"
  local items = M.list(scope)
  if #items == 0 then
    vim.notify("yap: no saved conversations in this scope", vim.log.levels.INFO)
    return
  end
  local scope_label = scope == "all" and "all projects" or "cwd project"
  local projects = {}
  for _, item in ipairs(items) do
    projects[vim.fn.fnamemodify(item.path, ":h:h")] = true
  end
  -- Reserve the status column even for closed rows (and when every row is
  -- closed), so descendants never shift as sessions open and close.
  local icon_width = picker.icon_width(picker.glyphs())
  local multiple_projects = scope == "all" and vim.tbl_count(projects) > 1
  vim.ui.select(items, {
    prompt = "Pick yap session (" .. scope_label .. ")",
    kind = "yap_session",
    format_item = function(item)
      local icon = opts.status and opts.status(item.path)
      local project = slug_cwd(vim.fn.fnamemodify(item.path, ":h:h"))
      local label = item.text
      -- list("all") prefixes roots for callers; move that identity to a
      -- suffix in the picker so titles remain aligned across projects.
      if scope == "all" and item.depth == 0 and vim.startswith(label, project .. "  ") then
        label = label:sub(#project + 3)
      end
      label = picker.prefix(icon, icon_width) .. label
      if item.turns then
        label = label .. "  (" .. item.turns .. (item.turns == 1 and " turn)" or " turns)")
      end
      if multiple_projects and item.depth == 0 then
        label = label .. "  " .. project
      end
      return label
    end,
    preview_item = preview_item,
  }, function(choice)
    if choice then
      on_choice(choice.path)
    end
  end)
end

--- Session title for the picker and notifications: `title` when set, else
--- `description`, else the filename. Subagents and forks are indented under
--- their parent when it is open. The project cwd is rendered separately by
--- |harness.instances|.
function M.live_label(buf, parent)
  local name = vim.api.nvim_buf_get_name(buf)
  local path = (name ~= "" and not name:match("^%a+://")) and name or (vim.b[buf].yap_path or name)
  local e = frontmatter.end_line(buf)
  local fm = e and frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false)) or nil
  local label = M.label(path, fm and fm.title, fm and fm.description)
  local role = fm and fm.agent or vim.b[buf].yap_agent
  if role then
    local task = M.task(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    local fallback = view.collapse(vim.b[buf].yap_subagent_task or "")
    label = M.agent_label(role, fm and fm.title, fm and fm.description, task, fallback, label)
  end
  if role and parent then
    return "↳ " .. label
  end
  if fm and fm.forked_from then
    return parent and "↳ fork · " .. label or "fork · " .. label .. " (parent not shown)"
  end
  if role and (fm and fm.subagent_parent or vim.b[buf].yap_subagent_parent) then
    return label .. " (parent not shown)"
  end
  return label
end

return M
