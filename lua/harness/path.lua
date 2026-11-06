-- Session path resolution — one place for the cwd↔slug transform, the
-- session name (its directory), and the derived file paths. The audit log
-- and notes are fixed-name siblings of the session markdown.

local M = {}

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

--- The XDG config home: `$XDG_CONFIG_HOME` when it is a non-empty absolute path
--- (the XDG spec ignores relative paths in these variables), otherwise the
--- standard `home()/.config`.
local function config_home()
  local xdg = vim.env.XDG_CONFIG_HOME
  if xdg and xdg ~= "" and vim.fn.isabsolutepath(xdg) == 1 then
    return vim.fs.normalize(xdg)
  end
  return home() .. "/.config"
end

-- The yap data root. These are DEFAULTS; yap.setup() may override them via
-- `agents_dir` / `sessions_dir`. A leading `~` is resolved against the real
-- home directory (see home()), never the current working directory, so yap's
-- data can never land inside the project.
M.dirs = {
  agents_dir = config_home() .. "/yap/agents",
  sessions_dir = config_home() .. "/yap/sessions",
}

--- The XDG config home (see config_home above), exported so every default
--- that points into yap's config directory resolves against the real home
--- directory. A relative or unset `$HOME` must never collapse a data path
--- into the project (R-data-paths).
function M.config_home()
  return config_home()
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
  vim.fn.mkdir(dir, "p")
  vim.fn.setfperm(dir, "rwx------")
end

--- Originating cwd for a persisted session file, from its directory slug.
--- Auto-generated sessions nest one level deeper
--- (<cwd-slug>/<yy-mm>/<session>/session.md), so the slug is not a fixed
--- depth from the file; walk up to the sessions root's immediate child.
function M.project_cwd(path)
  local root = M.sessions_root()
  local dir = vim.fn.fnamemodify(path, ":h")
  local parent = vim.fn.fnamemodify(dir, ":h")
  while parent ~= "" and parent ~= "/" and parent ~= root do
    dir = parent
    parent = vim.fn.fnamemodify(dir, ":h")
  end
  if parent == root then
    return unscream(vim.fn.fnamemodify(dir, ":t"))
  end
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

--- A fresh auto-named session directory under `dir`, grouped by month:
--- <dir>/<yy-mm>/<dd-hh.mm.ss>. A same-second collision would silently
--- overwrite the first transcript, so only then is a `-2`, `-3`, ... suffix
--- appended. Created 0700, ready for the first write.
local function fresh_session_dir(dir)
  local month_dir = dir .. "/" .. os.date("%y-%m")
  M.ensure_session_dir(month_dir) -- 0700; holds this month's sessions
  local stamp = os.date("%d-%H.%M.%S")
  local sdir = month_dir .. "/" .. stamp
  local n = 2
  while vim.fn.isdirectory(sdir) == 1 do
    sdir = month_dir .. "/" .. stamp .. "-" .. n
    n = n + 1
  end
  M.ensure_session_dir(sdir)
  return sdir
end

--- A fresh session path under `dir`: <dir>/<name>/session.md when `name` is
--- given, else <dir>/<yy-mm>/<dd-hh.mm.ss>/session.md (auto sessions group by
--- month). A same-second collision would silently overwrite the first
--- transcript, so only then is a `-2`, `-3`, ... suffix appended. The session
--- directory is created here (0700), ready for the first write.
function M.new_session_path(dir, name)
  if name then
    name = name:gsub("%.md$", "")
    local sdir = dir .. "/" .. name
    M.ensure_session_dir(sdir)
    return sdir .. "/session.md"
  end
  return fresh_session_dir(dir) .. "/session.md"
end

--- Whether a transcript lives under yap's sessions root. Transcripts inside
--- the root keep their sidecars beside them (the legacy layout); transcripts
--- elsewhere use a central data directory recorded in the frontmatter.
function M.under_sessions_root(path)
  local root = M.sessions_root()
  return path:sub(1, #root + 1) == root .. "/"
end

--- A fresh central data directory for a transcript that lives outside the
--- sessions root: sidecars (audit.jsonl, assets/) stay in yap's own tree
--- under the same month/stamp scheme as auto sessions. Nothing else lives
--- here, so it is never mistaken for a session directory.
function M.new_data_dir(cwd)
  return fresh_session_dir(M.session_dir(cwd))
end

--- The directory a subagent session belongs in: the parent's month folder
--- (<dir>/<yy-mm>) when the parent lives in one, else the current month. A
--- child is grouped with the conversation that spawned it, so subagent
--- sessions never litter the project root.
function M.child_session_dir(dir, parent_path)
  local month = vim.fn.fnamemodify(parent_path or "", ":h:h:t")
  if not month:match("^%d%d%-%d%d$") then
    -- The parent is a root-level (named) session: group by this month.
    month = os.date("%y-%m")
  end
  return dir .. "/" .. month
end

--- The session's directory name (the directory immediately above the
--- markdown file). It is the final fallback identity, not the display name:
--- the title (a renamed transcript) or the description win.
function M.session_name(path)
  return vim.fn.fnamemodify(path, ":h:t")
end

--- The transcript markdown file inside a session directory: the one `.md`
--- file that is not the scratch notes sidecar. Defaults to `session.md`.
--- The transcript is renamed to set the session title.
function M.transcript_in(dir)
  for _, f in ipairs(vim.fn.glob(dir .. "/*.md", false, true)) do
    if vim.fn.fnamemodify(f, ":t") ~= "notes.md" then
      return f
    end
  end
  return dir .. "/session.md"
end

--- All session directories under a cwd-slug `dir`. A session directory is one
--- that directly contains a transcript markdown file (any `.md` that is not
--- the scratch notes.md). Auto-named sessions nest one month-folder deep and
--- named forks/subagents sit at the top level, so the tree is walked rather
--- than assumed; `assets/` working-file folders are skipped, never sessions.
function M.session_dirs(dir)
  local out = {}
  local function walk(d)
    local transcript = false
    local subdirs = {}
    for name, type in vim.fs.dir(d) do
      if type == "directory" then
        if name ~= "assets" then
          subdirs[#subdirs + 1] = d .. "/" .. name
        end
      elseif type == "file" and name ~= "notes.md" and name:match("%.md$") then
        transcript = true
      end
    end
    if transcript then
      out[#out + 1] = d
      return
    end
    for _, sub in ipairs(subdirs) do
      walk(sub)
    end
  end
  walk(dir)
  return out
end

--- The live tool tail buffer's display name. The description is preferred;
--- the transcript filename and session directory are the fallbacks.
function M.tail_buf_name(buf, label)
  local path = M.session_path(buf) or vim.api.nvim_buf_get_name(buf)
  return "Yap Log: " .. (label or M.session_name(path))
end

--- The directory holding a session's sidecar data (audit log and assets).
--- For a transcript under the sessions root this is the transcript's own
--- directory (the legacy layout, so sidecars still move with a directory
--- rename). For a transcript elsewhere it is the central directory the
--- frontmatter records and the buffer keeps as `yap_data_dir`.
function M.data_dir(buf)
  if vim.b[buf].yap_data_dir and vim.b[buf].yap_data_dir ~= "" then
    return vim.fs.normalize(vim.b[buf].yap_data_dir)
  end
  local path = M.session_path(buf) or vim.api.nvim_buf_get_name(buf)
  return vim.fn.fnamemodify(path, ":h")
end

--- The session's JSON Lines audit log: <data_dir>/audit.jsonl. It follows the
--- session's data directory (see data_dir), not the current working
--- directory, so a session opened from another project still writes to its
--- own log.
function M.audit_path(buf)
  return M.data_dir(buf) .. "/audit.jsonl"
end

--- The session's file-backed jotter: <data_dir>/notes.md. Its fixed name is
--- excluded from transcript discovery; the session data directory follows the
--- transcript (or its frontmatter data_dir for portable sessions).
function M.notes_path(buf)
  return M.data_dir(buf) .. "/notes.md"
end

--- The session's assets folder: <data_dir>/assets. It is the session's single
--- working-files folder: dropped photos are copied here (the `![FILE: …](file://…)`
--- reference is the manifest), the backend writes live-tail logs, inline
--- scripts and header files here instead of the system temp dir, and the agent
--- writes its throwaway scripts, fetched downloads and generated artifacts here
--- too — so nothing scatters into /tmp or the project, everything moves with
--- the session's data directory, and the agent can find files it saved earlier
--- in the session.
function M.assets_dir(buf)
  return M.data_dir(buf) .. "/assets"
end

return M
