-- yap session persistence & picker.
--
-- A yap session is just the buffer's markdown written to a file — the
-- buffer IS the conversation, so the file is a lossless serialization.
-- Sessions live under ~/.yap/sessions/<cwd-slug>/ and are
-- autosaved after every completed reply. The resume picker identifies
-- sessions by their generated description; unnamed sessions (no description,
-- still on the auto-generated filename) are hidden, while open sessions stay
-- visible in :YapInstances via the filename fallback.

local M = {}

local frontmatter = require("harness.frontmatter")

local function sessions_root()
  return vim.fn.expand("~/.yap/sessions")
end

--- Root of all session files (~/.yap/sessions).
function M.sessions_root()
  return sessions_root()
end

--- Best-effort originating cwd for an existing persisted session.
function M.project_cwd(path)
  local dir = vim.fn.fnamemodify(path, ":h:t")
  return dir:sub(1, 1) == "-" and ("/" .. dir:sub(2):gsub("-", "/")) or dir:gsub("-", "/")
end

local function cwd_slug(cwd)
  return (cwd:gsub("[^%w%._-]", "-"))
end

local function session_dir(cwd)
  return sessions_root() .. "/" .. cwd_slug(vim.fs.normalize(cwd))
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
    local dir = session_dir(vim.fn.getcwd())
    vim.fn.mkdir(dir, "p")
    path = string.format("%s/%s-%04x.md", dir, os.date("%Y%m%d-%H%M%S"), math.random(0, 0xffff))
    vim.b[buf].yap_path = path
    pcall(vim.api.nvim_buf_set_name, buf, path)
  end
  local view = vim.api.nvim_get_current_buf() == buf and vim.fn.winsaveview() or nil
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent noautocmd keepjumps write!")
  end)
  if view then
    vim.fn.winrestview(view)
  end
end

-- First non-empty line of the first `# @user` block, compacted.
local function first_user_snippet(lines)
  local in_user = false
  for _, line in ipairs(lines) do
    if line:match("^# @%a+%s*$") then
      in_user = line:match("^# @user%s*$") ~= nil
    elseif in_user then
      local text = line:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      if text ~= "" then
        if #text > 60 then
          return text:sub(1, 60) .. "…"
        end
        return text
      end
    end
  end
  return ""
end

--- The persisted directory name is a lossy cwd slug; this is deliberately a
--- best-effort display conversion for saved cross-project sessions.
local function slug_cwd(dir)
  return M.project_cwd(dir .. "/session.md")
end

--- True when a session still carries the auto-generated filename from
--- save() (never named with :file). These are unnamed scratch sessions.
local function default_id(path)
  return vim.fn.fnamemodify(path, ":t"):match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%x%x%x%x%.md$") ~= nil
end

--- Shared picker identity: generated description, filename fallback. Project
--- overviews prefix the cwd so sessions from different worktrees are obvious.
function M.label(path, description, project_cwd)
  local filename = path and path ~= "" and vim.fn.fnamemodify(path, ":t") or nil
  local identity = description and description ~= "" and description or filename or "session"
  return project_cwd and project_cwd ~= "" and (project_cwd .. "  " .. identity) or identity
end

--- List saved sessions. scope = "cwd" (default) or "all".
--- Items: { path, mtime, text, model, models? } sorted newest first;
--- `model`/`models` come from the session frontmatter.
function M.list(scope)
  local dirs
  if scope == "all" then
    dirs = vim.fn.glob(sessions_root() .. "/*", false, true)
  else
    dirs = { session_dir(vim.fn.getcwd()) }
  end

  local items = {}
  for _, dir in ipairs(dirs) do
    for _, path in ipairs(vim.fn.glob(dir .. "/*.md", false, true)) do
      local lines = vim.fn.readfile(path, "", 200)
      local fm = frontmatter.parse(lines)
      local description = fm and fm.description or ""
      -- Hide unnamed sessions: no generated description and still on the
      -- auto-generated filename. They stay visible as open sessions via
      -- :YapInstances, which falls back to the filename.
      local unnamed = description == "" and default_id(path)
      if not unnamed then
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
  local lines = vim.fn.readfile(item.path)
  local n = math.min(80, #lines)
  local preview = { "# yap session" .. (item.model and (" · " .. item.model) or "") }
  if item.models then
    table.insert(preview, "used: " .. table.concat(item.models, " · "))
  end
  table.insert(preview, "")
  table.insert(preview, item.path)
  table.insert(preview, "")
  table.insert(preview, "showing last " .. n .. "/" .. #lines .. " lines")
  table.insert(preview, "")
  for i = #lines - n + 1, #lines do
    table.insert(preview, lines[i])
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, preview)
  vim.bo[buf].bufhidden = "wipe"
  return { buf = buf, pos = { 1, 0 } }
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
