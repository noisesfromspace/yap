-- yap session persistence & picker.
--
-- A yap session is just the buffer's markdown written to a file — the
-- buffer IS the conversation, so the file is a lossless serialization.
-- Sessions live under ~/.yap/sessions/<cwd-slug>/ and are
-- autosaved after every completed reply. Pickers identify sessions by their
-- chosen name (a :file rename) or generated description; unnamed sessions
-- (no description, still on the auto-generated filename) are hidden unless
-- they have subagents; open sessions stay visible in :YapInstances via the
-- filename fallback. Saved subagents appear beneath their parent in history.

local M = {}

local frontmatter = require("harness.frontmatter")
local paths = require("harness.path")

function M.sessions_root()
  return paths.sessions_root()
end

--- Best-effort originating cwd for an existing persisted session.
function M.project_cwd(path)
  return paths.project_cwd(path)
end

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
--- a block are skipped.
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
    return -- unchanged: skip the rewrite so an untouched block stays clean
  end
  local block = frontmatter.render(fm.provider, fm.model, fm.models, fm.created_at, fm.description, fm.role, fm.tools, fm.subagents, updated_at, turns, fm.cwd, fm.forked_from, fm.forks, fm.subagent_parent)
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
    vim.fs.mkdir(dir, { parents = true })
    path = paths.new_session_path(dir)
    vim.b[buf].yap_path = path
    vim.npcall(vim.api.nvim_buf_set_name, buf, path)
  end
  stamp_updated_at(buf)
  local view = vim.api.nvim_get_current_buf() == buf and vim.fn.winsaveview() or nil
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent noautocmd keepjumps write!")
  end)
  if view then
    vim.fn.winrestview(view)
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
  vim.fs.mkdir(dir, { parents = true })
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
      if lines[i] == "# @assistant" then current_assistant = i; break end
    end
    if current_assistant then
      for i = current_assistant - 1, 1, -1 do
        if lines[i] == "# @user" then
          lines = vim.list_slice(lines, 1, i - 1)
          while lines[#lines] == "" do table.remove(lines) end
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
      if lines[i]:match("^%-%-%-%s*$") then ending = i; break end
    end
    if ending then
      local created = os.date("!%Y-%m-%dT%H:%M:%SZ")
      local turns = 0
      for i = ending + 1, #lines do
        if lines[i] == "# @assistant" then turns = turns + 1 end
      end
      local block = frontmatter.render(fm.provider, fm.model, fm.models, created, fm.description, fm.role, fm.tools, fm.subagents, created, turns, fm.cwd, vim.b[buf].yap_path, {}, nil)
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
    local dest = paths.audit_dir(vim.fn.getcwd()) .. "/" .. vim.fn.fnamemodify(path, ":t:r") .. ".jsonl"
    vim.fs.mkdir(vim.fn.fnamemodify(dest, ":h"), { parents = true, mode = 448 }) -- 0700
    local copied, copy_err
    if running then
      local events, last_turn = {}, 0
      for _, line in ipairs(vim.fn.readfile(audit)) do
        events[#events + 1] = line
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" and ev.type == "turn_end" then last_turn = #events end
      end
      copied, copy_err = pcall(vim.fn.writefile, vim.list_slice(events, 1, last_turn), dest)
    else
      copied, copy_err = vim.uv.fs_copyfile(audit, dest)
    end
    if not copied then
      vim.fn.delete(path)
      return nil, "cannot copy fork audit: " .. tostring(copy_err)
    end
  end
  -- A running source persists this link on its normal turn-end save.
  if fm then
    local source_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local source_fm = frontmatter.parse(source_lines)
    local forks = source_fm.forks or {}
    forks[#forks + 1] = path
    local ending
    for i = 2, #source_lines do
      if source_lines[i]:match("^%-%-%-%s*$") then ending = i; break end
    end
    local block = frontmatter.render(source_fm.provider, source_fm.model, source_fm.models, source_fm.created_at, source_fm.description, source_fm.role, source_fm.tools, source_fm.subagents, source_fm.updated_at, source_fm.turns, source_fm.cwd, source_fm.forked_from, forks, source_fm.subagent_parent)
    vim.api.nvim_buf_set_lines(buf, 0, ending, false, block)
  end
  return path
end

local function trim_block(acc)
  while #acc > 0 and acc[1]:match("^%s*$") do
    table.remove(acc, 1)
  end
  while #acc > 0 and acc[#acc]:match("^%s*$") do
    table.remove(acc)
  end
  return acc
end

-- Body of the first `# @role` block, heading excluded, surrounding
-- blank lines trimmed.
local function first_block(lines, role)
  local acc = {}
  local in_block = false
  for _, line in ipairs(lines) do
    local heading = line:match("^# @(%a+)%s*$")
    if heading then
      if in_block then
        break
      end
      in_block = heading == role
    elseif in_block then
      acc[#acc + 1] = line
    end
  end
  return trim_block(acc)
end

-- Body of the last `# @role` block, heading excluded, surrounding
-- blank lines trimmed.
local function last_block(lines, role)
  local acc = {}
  local in_block = false
  for _, line in ipairs(lines) do
    local heading = line:match("^# @(%a+)%s*$")
    if heading then
      in_block = heading == role
      if in_block then
        acc = {}
      end
    elseif in_block then
      acc[#acc + 1] = line
    end
  end
  return trim_block(acc)
end

--- Markdown preview of a session: the initial `# @user` message followed by
--- the last `# @assistant` answer, rendered in a scratch buffer with the
--- `markdown` filetype so pickers show it with normal syntax highlighting
--- instead of flat text. Shared by :YapInstances and :YapSessions so both
--- pickers preview the same two excerpts. Returns the |vim.ui.select()|
--- preview table `{ buf = ... }`.
function M.preview(lines)
  local content = {}
  local user = first_block(lines, "user")
  local assistant = last_block(lines, "assistant")
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
  local identity = named and filename
    or (description and description ~= "" and description or filename or "session")
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
        if fm and fm.role then
          local task
          for i, line in ipairs(lines) do
            if line == "# @user" then
              for j = i + 1, #lines do
                if lines[j]:match("^# @%a+") then break end
                if lines[j]:match("%S") then task = lines[j]:gsub("^%s+", ""):gsub("%s+$", ""); break end
              end
              break
            end
          end
          item.text = "↳ " .. fm.role .. " · " .. (description ~= "" and description or task or name)
          children[path] = item
        elseif (not paths.is_default_name(path) or description ~= "" or (fm and (#fm.subagents > 0 or fm.forked_from or #fm.forks > 0)))
            and (not renamed_only or not paths.is_default_name(path)) then
          items[#items + 1] = item
        end
        if fm then
          for _, child_path in ipairs(fm.subagents) do parents[vim.fs.normalize(child_path)] = path end
        end
      end
    end
  end

  table.sort(items, function(a, b) return a.mtime > b.mtime end)
  local result = {}
  for _, item in ipairs(items) do
    result[#result + 1] = item
    local owned = {}
    for path, child in pairs(children) do
      if parents[vim.fs.normalize(path)] == item.path then owned[#owned + 1] = child end
    end
    table.sort(owned, function(a, b) return a.mtime > b.mtime end)
    for _, child in ipairs(owned) do
      child.text = "  " .. child.text
      result[#result + 1] = child
      children[child.path] = nil
    end
  end
  -- Preserve discoverability if a parent was deleted or is hidden by scope.
  if not renamed_only then
    local orphans = {}
    for _, child in pairs(children) do orphans[#orphans + 1] = child end
    table.sort(orphans, function(a, b) return a.mtime > b.mtime end)
    for _, child in ipairs(orphans) do
      if scope == "all" then child.text = slug_cwd(vim.fn.fnamemodify(child.path, ":h")) .. "  " .. child.text end
      result[#result + 1] = child
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
    local msg = scope == "renamed" and "yap: no renamed conversations in this project" or "yap: no saved conversations in this scope"
    vim.notify(msg, vim.log.levels.INFO)
    return
  end
  local scope_label = scope == "all" and "all projects" or scope == "renamed" and "renamed, cwd project" or "cwd project"
  vim.ui.select(items, {
    prompt = "Pick yap session (" .. scope_label .. ")",
    kind = "yap_session",
    format_item = function(item)
      local status = opts.status and opts.status(item.path)
      local label = item.text
      if status then
        label = label .. "  " .. status
      end
      if item.turns then
        return label .. "  (" .. item.turns .. (item.turns == 1 and " turn)" or " turns)")
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
