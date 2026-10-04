-- yap session persistence & picker.
--
-- A yap session is just the buffer's markdown written to a file — the
-- buffer IS the conversation, so the file is a lossless serialization.
-- Sessions live under ~/.yap/sessions/<cwd-slug>/ and are
-- autosaved after every completed reply. Pickers identify sessions by their
-- chosen name (a :file rename) or generated description; unnamed sessions
-- (no description, still on the auto-generated filename) are hidden, while
-- open sessions stay visible in :YapInstances via the filename fallback.

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
--- Stamp `updated_at` in the frontmatter to now, immediately before the
--- buffer is written. This is the only place `updated_at` is set; every
--- other frontmatter rewrite preserves it, so the field means "last write".
--- Cheap: only the frontmatter block (capped at 200 lines) is re-read and
--- rewritten, once per save — never on keystrokes or redraws. Legacy files
--- without a block are skipped.
local function stamp_updated_at(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 200, false)
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
  local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
  if not fm then
    return
  end
  local updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  if fm.updated_at == updated_at then
    return -- same second: skip the rewrite so an unchanged block stays clean
  end
  local block = frontmatter.render(fm.provider, fm.model, fm.models, fm.created_at, fm.description, fm.role, fm.tools, fm.subagents, updated_at)
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
    vim.fn.mkdir(dir, "p")
    path = paths.new_session_path(dir)
    vim.b[buf].yap_path = path
    pcall(vim.api.nvim_buf_set_name, buf, path)
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

--- Preview content for a session: the initial `# @user` message followed by
--- the last `# @assistant` answer. Shared by :YapInstances and :YapSessions
--- so both pickers preview the same two excerpts.
function M.preview_lines(lines)
  local preview = {}
  local user = first_block(lines, "user")
  local assistant = last_block(lines, "assistant")
  if #user > 0 then
    preview[#preview + 1] = "Initial user message:"
    vim.list_extend(preview, user)
  end
  if #assistant > 0 then
    if #preview > 0 then
      preview[#preview + 1] = ""
    end
    preview[#preview + 1] = "Last agent answer:"
    vim.list_extend(preview, assistant)
  end
  if #preview == 0 then
    preview = { "(no messages yet)" }
  end
  return preview
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

--- List saved sessions. scope = "cwd" (default) or "all".
--- Items: { path, mtime, text, model, models? } sorted newest first;
--- `model`/`models` come from the session frontmatter.
function M.list(scope)
  local dirs
  if scope == "all" then
    dirs = vim.fn.glob(paths.sessions_root() .. "/*", false, true)
  else
    dirs = { paths.session_dir(vim.fn.getcwd()) }
  end

  local items = {}
  for _, dir in ipairs(dirs) do
    for _, path in ipairs(vim.fn.glob(dir .. "/*.md", false, true)) do
      local lines = vim.fn.readfile(path, "", 200)
      local fm = frontmatter.parse(lines)
      -- Subagent sessions are real saved sessions, but they belong to their
      -- parent: hide them from the session history. While open they appear
      -- in :YapInstances; once closed, the parent's frontmatter `subagents`
      -- list is the only index of them.
      local subagent = fm and fm.role ~= nil
      local description = fm and fm.description or ""
      -- Hide unnamed sessions: no generated description and still on the
      -- auto-generated filename. They stay visible as open sessions via
      -- :YapInstances, which falls back to the filename.
      local unnamed = description == "" and paths.is_default_name(path)
      if not subagent and not unnamed then
        local model = fm and fm.provider and fm.model and (fm.provider .. "/" .. fm.model) or nil
        table.insert(items, {
          path = path,
          mtime = vim.fn.getftime(path),
          text = M.label(path, description, scope == "all" and slug_cwd(dir) or nil),
          model = model,
          models = (fm and #fm.models > 1) and fm.models or nil,
        })
      end
    end
  end

  table.sort(items, function(a, b)
    return a.mtime > b.mtime
  end)
  return items
end

local function preview_item(item)
  return M.preview_lines(vim.fn.readfile(item.path))
end

--- Pick a session; on_choice(path) is called with the selected file.
function M.pick(opts, on_choice)
  opts = opts or {}
  local items = M.list(opts.scope == "all" and "all" or "cwd")
  if #items == 0 then
    vim.notify("yap: no saved sessions", vim.log.levels.INFO)
    return
  end
  vim.ui.select(items, {
    prompt = "Pick yap session (" .. (opts.scope == "all" and "all projects" or "cwd project") .. ")",
    kind = "yap_session",
    format_item = function(item)
      return item.text
    end,
    preview_item = preview_item,
  }, function(choice)
    if choice then
      on_choice(choice.path)
    end
  end)
end

return M
