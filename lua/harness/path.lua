-- Session path resolution — one place for the cwd↔slug transform, the
-- session name (its directory), and the derived file paths. The audit log
-- and notes are fixed-name siblings of the session markdown.

local M = {}

-- The .yap data root. This is the DEFAULT; yap.setup() may override it via
-- `sessions_dir`. A leading `~` is resolved against the real home directory
-- (see home()), never the current working directory, so yap's data can never
-- land inside the project.
M.dirs = {
  sessions_dir = "~/.yap/sessions",
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

function M.session_dir(cwd)
  return M.sessions_root() .. "/" .. cwd_slug(cwd)
end

--- Ensure a session directory exists and is private (0700): it holds the
--- conversation markdown, notes, and audit log — all of which can contain
--- secrets. Matches the old per-project audit-dir posture, now that audit
--- logs are co-located here.
function M.ensure_session_dir(dir)
  vim.fs.mkdir(dir, { parents = true })
  vim.fn.setfperm(dir, "rwx------")
end

--- Originating cwd for a persisted session file, from its directory slug.
--- A session lives at <sessions>/<cwd-slug>/<session>/session.md, so the
--- slug is two levels up from the markdown file.
function M.project_cwd(path)
  return unscream(vim.fn.fnamemodify(path, ":h:h:t"))
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

-- Auto-generated session names: <timestamp>-<hex> (the directory name). The
-- pattern below is the exact inverse of new_session_path's format string —
-- keep them together, or unnamed sessions leak into the picker / get hidden.
local DEFAULT_NAME = "^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%x%x%x%x$"

--- A fresh session path under `dir`: <dir>/<name>/session.md, with the
--- session named by its directory. `name` (optional) is the session base
--- name; without it an auto-generated timestamp+hex name is used. The
--- session directory is created here (0700), ready for the first write.
function M.new_session_path(dir, name)
  name = (name and name:gsub("%.md$", "")) or string.format("%s-%04x", os.date("%Y%m%d-%H%M%S"), math.random(0, 0xffff))
  local sdir = dir .. "/" .. name
  M.ensure_session_dir(sdir)
  return sdir .. "/session.md"
end

--- The session's name: the directory immediately above the markdown file.
--- Sessions are <dir>/<name>/session.md, so the name is the directory and
--- renaming the directory renames the session everywhere it is displayed.
function M.session_name(path)
  return vim.fn.fnamemodify(path, ":h:t")
end

--- True when the session directory still carries the auto-generated name
--- (never renamed). These are unnamed scratch sessions.
function M.is_default_name(path)
  return M.session_name(path):match(DEFAULT_NAME) ~= nil
end

--- The audit view buffer's name; mirrors the session name (its directory)
--- so a renamed session keeps its audit view.
function M.audit_buf_name(buf)
  local path = M.session_path(buf) or vim.api.nvim_buf_get_name(buf)
  return "yap://" .. M.session_name(path) .. "-audit"
end

--- The session's JSON Lines audit log: <dir>/audit.jsonl, beside the session
--- markdown. It follows the session directory, not the current working
--- directory, so a session opened from another project still writes to its
--- own log.
function M.audit_path(buf)
  local path = M.session_path(buf) or vim.api.nvim_buf_get_name(buf)
  return vim.fn.fnamemodify(path, ":h") .. "/audit.jsonl"
end

--- The session's scratch notes file: <dir>/notes.md, beside the session
--- markdown. The `.md` extension gives it markdown highlighting in editors
--- that open it directly; the scratch buffer itself is created without
--- filetype detection, so no LSP clients attach to it.
function M.notes_path(buf)
  local path = M.session_path(buf) or vim.api.nvim_buf_get_name(buf)
  return vim.fn.fnamemodify(path, ":h") .. "/notes.md"
end

return M
