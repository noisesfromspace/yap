-- Session/audit/queue path resolution — one place for the cwd↔slug
-- transform and the derived file paths. Sessions and audit logs key off the
-- same slug, and :YapClear placeholders point into the audit dir, so the
-- transform must live once, not be re-derived inline.

local M = {}

-- The .yap data roots. These are the DEFAULTS; yap.setup() may override
-- them via `sessions_dir` / `audit_dir`. A leading `~` is resolved against
-- the real home directory (see home()), never the current working
-- directory, so yap's data can never land inside the project.
M.dirs = {
  sessions_dir = "~/.yap/sessions",
  audit_dir = "~/.yap/audit",
}

local cached_home

--- The user's home directory, resolved so it can never collapse to the
--- current working directory. `$HOME` wins when it is a non-empty absolute
--- path; otherwise the passwd entry (via libuv) supplies the home, which
--- covers `$HOME` unset, empty, or relative — the cases where
--- `vim.fn.expand("~")` silently falls back to the project directory.
local function home()
  if cached_home then
    return cached_home
  end
  local h = vim.env.HOME
  if h and h ~= "" and vim.fn.isabsolutepath(h) == 1 then
    cached_home = vim.fs.normalize(h)
    return cached_home
  end
  local ok, p = pcall(vim.uv.os_get_passwd)
  if ok and p and p.homedir and p.homedir ~= "" then
    cached_home = vim.fs.normalize(p.homedir)
    return cached_home
  end
  error("yap: cannot resolve home directory (HOME is unset, empty, or relative)")
end

--- Expand a data-path setting: a leading `~` resolves against home(), an
--- absolute path passes through. A relative path is refused — yap's data
--- directories must never be resolved against the project directory.
function M.expand(path)
  if path:sub(1, 1) == "~" then
    return vim.fs.normalize(home() .. path:sub(2))
  end
  if vim.fn.isabsolutepath(path) == 1 then
    return vim.fs.normalize(path)
  end
  error("yap: data path must be absolute or start with ~: " .. path)
end

--- cwd → slug. The round-trip is lossy (a literal "-" in a path component
--- is indistinguishable from a separator), which is accepted: it is a
--- best-effort display conversion, not a key.
local function cwd_slug(cwd)
  return (vim.fs.normalize(cwd):gsub("[^%w%._-]", "-"))
end

--- slug → best-effort cwd. A leading "-" means the slug came from an
--- absolute path, so a "/" is prepended after unslugging.
local function unscream(slug)
  return slug:sub(1, 1) == "-" and ("/" .. slug:sub(2):gsub("-", "/")) or slug:gsub("-", "/")
end

function M.sessions_root()
  return M.expand(M.dirs.sessions_dir)
end

function M.audit_root()
  return M.expand(M.dirs.audit_dir)
end

function M.session_dir(cwd)
  return M.sessions_root() .. "/" .. cwd_slug(cwd)
end

function M.audit_dir(cwd)
  return M.audit_root() .. "/" .. cwd_slug(cwd)
end

--- Originating cwd for a persisted session file, from its directory slug.
function M.project_cwd(path)
  return unscream(vim.fn.fnamemodify(path, ":h:t"))
end

--- cwd display for a sessions-root subdirectory (the "all projects" scope).
--- `dir` is a full directory path; only its basename is the slug.
function M.slug_cwd(dir)
  return unscream(vim.fn.fnamemodify(dir, ":t"))
end

--- The session file path, or nil for a not-yet-named buffer.
function M.session_path(buf)
  return vim.b[buf].yap_path
end

-- Auto-generated session filenames: <timestamp>-<hex>.md. The pattern below
-- is the exact inverse of new_session_path's format string — keep them
-- together, or unnamed sessions leak into the picker / get hidden.
local DEFAULT_NAME = "^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%x%x%x%x%.md$"

--- A fresh, never-yet-named session file path under `dir`.
function M.new_session_path(dir)
  return string.format("%s/%s-%04x.md", dir, os.date("%Y%m%d-%H%M%S"), math.random(0, 0xffff))
end

--- True when `path` still carries the auto-generated filename (never named
--- with :file). These are unnamed scratch sessions.
function M.is_default_name(path)
  return vim.fn.fnamemodify(path, ":t"):match(DEFAULT_NAME) ~= nil
end

--- Session basename (no extension); falls back to the buffer name.
function M.session_base(buf)
  local path = M.session_path(buf)
  if path then
    return vim.fn.fnamemodify(path, ":t:r")
  end
  return vim.api.nvim_buf_get_name(buf):gsub("^yap://", ""):gsub("[^%w%._-]", "-")
end

--- The tail buffer's name; mirrors the session basename so `:file` renames
--- keep the two together.
function M.tail_buf_name(buf)
  local path = M.session_path(buf) or vim.api.nvim_buf_get_name(buf)
  return "yap://" .. vim.fn.fnamemodify(path, ":t") .. "-tail"
end

--- The session's JSON Lines audit log.
function M.audit_path(buf)
  return M.audit_dir(vim.fn.getcwd()) .. "/" .. M.session_base(buf) .. ".jsonl"
end

--- The session's scratch queue file (a sibling of the session file).
function M.queue_path(buf)
  local path = M.session_path(buf) or vim.api.nvim_buf_get_name(buf)
  return vim.fn.fnamemodify(path, ":r") .. ".queue"
end

return M
