-- yap session persistence & picker.
--
-- A yap session is just the buffer's markdown written to a file — the
-- buffer IS the conversation, so the file is a lossless serialization.
-- Sessions live under ~/.yap/sessions/<cwd-slug>/ and are
-- autosaved after every completed reply. Pickers identify sessions by their
-- chosen name (a :file rename) or generated description; unnamed sessions
-- (no description, still on the auto-generated filename) are hidden unless
-- they have subagents or hold an unsent `# @user` prompt (a scheduled
-- prompt); open sessions stay visible in the open-session picker via the
-- filename fallback. Saved subagents appear beneath their parent in history.

local M = {}

local frontmatter = require("harness.frontmatter")
local paths = require("harness.path")

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
--- The rewrite is skipped when neither field changed. Legacy files without
--- frontmatter are skipped.
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
  -- Merge assets staged by attachment.attach() (buffer-local, deferred here
  -- so attaching never rewrites the frontmatter mid-import and shifts the
  -- line numbers import_paths is iterating).
  local assets = fm.assets or {}
  local added = false
  local pending = vim.b[buf].yap_assets
  if pending then
    for _, a in ipairs(pending) do
      local dup = false
      for _, x in ipairs(assets) do
        if x == a then
          dup = true
          break
        end
      end
      if not dup then
        assets[#assets + 1] = a
        added = true
      end
    end
    vim.b[buf].yap_assets = nil
  end
  local updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  if fm.updated_at == updated_at and fm.turns == turns and not added then
    return -- unchanged: skip the rewrite so an untouched frontmatter stays clean
  end
  local block = frontmatter.render(
    fm.provider,
    fm.model,
    fm.models,
    fm.created_at,
    fm.description,
    fm.agent,
    fm.tools,
    fm.subagents,
    updated_at,
    turns,
    fm.created_cwd,
    fm.forked_from,
    fm.forks,
    fm.subagent_parent,
    assets
  )
  vim.api.nvim_buf_set_lines(buf, 0, e, false, block)
end

function M.save(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local path = vim.b[buf].yap_path
  local bufname = vim.api.nvim_buf_get_name(buf)
  -- Follow buffer renames (:file, :saveas): renaming the file IS session
  -- naming, and :saveas to a new file IS forking.
  if path and bufname ~= "" and bufname ~= path and not bufname:match("^%a+://") then
    path = bufname
    vim.b[buf].yap_path = path
  end
  if not path then
    local dir = paths.session_dir(vim.fn.getcwd())
    paths.ensure_session_dir(dir)
    path = paths.new_session_path(dir)
    vim.b[buf].yap_path = path
    vim.npcall(vim.api.nvim_buf_set_name, buf, path)
  end
  stamp_updated_at(buf)
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

-- Track whether a buffer-name change was a `:file` rename (move the sidecar
-- files) or a `:saveas` copy (copy them). Both change the buffer name and
-- fire BufFilePost; `:saveas` additionally writes in the same command, which
-- arrives as BufWritePre before the deferred decision lands. A `:file` rename
-- is left for audit.follow_rename and scratch.notes_follow to move lazily; a
-- `:saveas` copy is rehomed eagerly so the original session keeps its files.
local rename_pending = {} -- [buf] = "copy" | "move"

--- BufFilePost: the buffer name changed. Default to a `:file` rename; a
--- BufWritePre in the same command flips it to `:saveas` (see rename_write).
function M.rename_post(buf)
  rename_pending[buf] = "move"
  vim.schedule(function()
    local is_copy = rename_pending[buf] == "copy"
    rename_pending[buf] = nil
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if is_copy then
      -- `:saveas` continues in the same buffer under a new name. Retarget the
      -- sidecars immediately so the original session keeps its history and the
      -- copy's next turn appends to its own files (session.save() just
      -- records the name change; it does not move sidecars).
      local old_path = vim.b[buf].yap_path
      local new_path = vim.api.nvim_buf_get_name(buf)
      if old_path and old_path ~= new_path and new_path ~= "" and not new_path:match("^%a+://") then
        vim.b[buf].yap_path = new_path
        vim.fn.setfperm(new_path, "rw-------") -- the copy holds the same conversation
        require("harness.audit").rehome_copy(buf)
        require("harness.scratch").rehome_copy(buf, old_path)
      end
    end
  end)
end

--- BufWritePre: a write in the same command as the name change means the
--- change was `:saveas` (copy), not a bare `:file` rename.
function M.rename_write(buf)
  if rename_pending[buf] then
    rename_pending[buf] = "copy"
  end
end

--- Copy the current in-memory transcript to a new session file. Do not rename
--- or save the source buffer: its process, audit view, and unsaved edits belong
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
    path = dir .. "/" .. name
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
      local block = frontmatter.render(
        fm.provider,
        fm.model,
        fm.models,
        created,
        fm.description,
        fm.agent,
        fm.tools,
        fm.subagents,
        created,
        turns,
        fm.created_cwd,
        vim.b[buf].yap_path,
        {},
        nil,
        fm.assets
      )
      vim.list_extend(block, vim.list_slice(lines, ending + 1))
      lines = block
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
    local dest = vim.fn.fnamemodify(path, ":r") .. ".jsonl"
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
    local ending
    for i = 2, #source_lines do
      if source_lines[i]:match("^%-%-%-%s*$") then
        ending = i
        break
      end
    end
    local block = frontmatter.render(
      source_fm.provider,
      source_fm.model,
      source_fm.models,
      source_fm.created_at,
      source_fm.description,
      source_fm.agent,
      source_fm.tools,
      source_fm.subagents,
      source_fm.updated_at,
      source_fm.turns,
      source_fm.created_cwd,
      source_fm.forked_from,
      forks,
      source_fm.subagent_parent,
      source_fm.assets
    )
    vim.api.nvim_buf_set_lines(buf, 0, ending, false, block)
  end
  return path
end

local function trim_message(acc)
  while #acc > 0 and acc[1]:match("^%s*$") do
    table.remove(acc, 1)
  end
  while #acc > 0 and acc[#acc]:match("^%s*$") do
    table.remove(acc)
  end
  return acc
end

-- Body of the first `# @role` message, heading excluded, surrounding
-- blank lines trimmed.
local function first_message(lines, role)
  local acc = {}
  local in_message = false
  for _, line in ipairs(lines) do
    local heading = line:match("^# @(%a+)%s*$")
    if heading then
      if in_message then
        break
      end
      in_message = heading == role
    elseif in_message then
      acc[#acc + 1] = line
    end
  end
  return trim_message(acc)
end

-- Body of the last `# @role` message, heading excluded, surrounding
-- blank lines trimmed.
local function last_message(lines, role)
  local acc = {}
  local in_message = false
  for _, line in ipairs(lines) do
    local heading = line:match("^# @(%a+)%s*$")
    if heading then
      in_message = heading == role
      if in_message then
        acc = {}
      end
    elseif in_message then
      acc[#acc + 1] = line
    end
  end
  return trim_message(acc)
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

--- Markdown preview of a session: the initial `# @user` message followed by
--- the last `# @assistant` answer, rendered in a scratch buffer with the
--- `markdown` filetype so pickers show it with normal syntax highlighting
--- instead of flat text. Shared by the open-session and saved-session pickers so both
--- pickers preview the same two excerpts. Returns the |vim.ui.select()|
--- preview table `{ buf = ... }`.
function M.preview(lines)
  local content = {}
  local user = first_message(lines, "user")
  local assistant = last_message(lines, "assistant")
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

--- Shared picker identity. A session named with :file keeps that name in
--- every view, over any generated description; only auto-generated filenames
--- fall back to the description (then the filename). Project overviews prefix
--- the cwd so sessions from different worktrees are obvious.
function M.label(path, description, project_cwd)
  local filename = path and path ~= "" and vim.fn.fnamemodify(path, ":t") or nil
  local named = filename ~= nil and not paths.is_default_name(path)
  local identity = named and filename or (description and description ~= "" and description or filename or "session")
  return project_cwd and project_cwd ~= "" and (project_cwd .. "  " .. identity) or identity
end

--- List saved sessions. scope = "cwd" (default), "all", or "renamed"
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
  -- "renamed" narrows the history to sessions named with :file (a custom
  -- filename), as opposed to description-labelled auto-generated names.
  local renamed_only = scope == "renamed"

  local items, children, parents = {}, {}, {}
  for _, dir in ipairs(dirs) do
    for name, type in vim.fs.dir(dir) do
      -- glob("*.md") skips dotfiles; vim.fs.dir does not.
      if type == "file" and name:sub(1, 1) ~= "." and name:match("%.md$") then
        local path = vim.fs.joinpath(dir, name)
        local lines = vim.fn.readfile(path, "", 200)
        local fm = frontmatter.parse(lines)
        local description = fm and fm.description or ""
        local item = {
          path = path,
          mtime = vim.fn.getftime(path),
          text = M.label(path, description, scope == "all" and slug_cwd(dir) or nil),
          model = fm and fm.provider and fm.model and (fm.provider .. "/" .. fm.model) or nil,
          models = fm and #fm.models > 1 and fm.models or nil,
          turns = fm and fm.turns,
        }
        if fm and fm.agent then
          item.text = "↳ " .. fm.agent .. " · " .. ((description ~= "" and description) or M.task(lines) or name)
          children[path] = item
        elseif fm and fm.forked_from then
          item.text = "↳ fork · " .. M.label(path, description)
          children[path] = item
          parents[vim.fs.normalize(path)] = vim.fs.normalize(fm.forked_from)
        elseif
          (
            not paths.is_default_name(path)
            or description ~= ""
            or (fm and (#fm.subagents > 0 or fm.forked_from or #fm.forks > 0))
            or has_pending_user_text(path, lines)
          ) and (not renamed_only or not paths.is_default_name(path))
        then
          items[#items + 1] = item
        end
        if fm then
          for _, child_path in ipairs(fm.subagents) do
            parents[vim.fs.normalize(child_path)] = path
          end
        end
      end
    end
  end

  table.sort(items, function(a, b)
    return a.mtime > b.mtime
  end)
  local result, shown = {}, {}
  local function add(item, depth)
    if shown[item.path] then
      return
    end
    shown[item.path] = true
    item.depth = depth
    if depth > 0 then
      item.text = string.rep("  ", depth) .. item.text
    end
    result[#result + 1] = item
    local owned = {}
    for path, child in pairs(children) do
      if parents[vim.fs.normalize(path)] == vim.fs.normalize(item.path) then
        owned[#owned + 1] = child
      end
    end
    table.sort(owned, function(a, b)
      return a.mtime > b.mtime
    end)
    for _, child in ipairs(owned) do
      add(child, depth + 1)
    end
  end
  for _, item in ipairs(items) do
    add(item, 0)
  end
  -- Preserve discoverability when a parent is missing or excluded by scope.
  -- In renamed history, only custom-named orphans qualify; descendants of
  -- named roots are already included by add() regardless of their names.
  local orphans = {}
  for _, child in pairs(children) do
    if not shown[child.path] and (not renamed_only or not paths.is_default_name(child.path)) then
      orphans[#orphans + 1] = child
    end
  end
  table.sort(orphans, function(a, b)
    return a.mtime > b.mtime
  end)
  for _, child in ipairs(orphans) do
    if not shown[child.path] then
      child.text = child.text:sub(#"↳ " + 1) .. " (parent not shown)"
      if scope == "all" then
        child.text = slug_cwd(vim.fn.fnamemodify(child.path, ":h")) .. "  " .. child.text
      end
      add(child, 0)
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
    local msg = scope == "renamed" and "yap: no renamed conversations in this project"
      or "yap: no saved conversations in this scope"
    vim.notify(msg, vim.log.levels.INFO)
    return
  end
  local scope_label = scope == "all" and "all projects"
    or scope == "renamed" and "renamed, cwd project"
    or "cwd project"
  local projects = {}
  local icon_width = 1
  for _, item in ipairs(items) do
    projects[vim.fn.fnamemodify(item.path, ":h")] = true
    local status = opts.status and opts.status(item.path)
    if status then
      icon_width = math.max(icon_width, vim.fn.strdisplaywidth(status))
    end
  end
  local multiple_projects = scope == "all" and vim.tbl_count(projects) > 1
  vim.ui.select(items, {
    prompt = "Pick yap session (" .. scope_label .. ")",
    kind = "yap_session",
    format_item = function(item)
      local icon = opts.status and opts.status(item.path)
      local project = slug_cwd(vim.fn.fnamemodify(item.path, ":h"))
      local label = item.text
      -- list("all") prefixes roots for callers; move that identity to a
      -- suffix in the picker so titles remain aligned across projects.
      if scope == "all" and item.depth == 0 and vim.startswith(label, project .. "  ") then
        label = label:sub(#project + 3)
      end
      local prefix = (icon or "") .. string.rep(" ", icon_width - (icon and vim.fn.strdisplaywidth(icon) or 0))
      label = prefix .. "  " .. label
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

return M
