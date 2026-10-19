-- Request-only "hidden" context: transient, environment-dependent state
-- (cwd, git status, ...) that is appended to the trailing user message on
-- every send. It is never stored in the session buffer — editing the buffer
-- cannot disturb it — and it sits after the stable conversation history, so
-- a changing git status never invalidates the prompt's cached prefix.
--
-- Providers are functions returning a string (or nil/"" to contribute
-- nothing). Built-ins register themselves below; plugins add more with
-- `require("harness.model.context").register(fn[, order])`.

local M = {}

local providers = {}

--- Register a context provider. `fn()` runs on every send with no arguments
--- and returns a string to append, or nil/"" to skip. Lower `order` runs
--- first; built-ins use 10 (cwd) and 20 (git).
function M.register(fn, order)
  vim.validate({ fn = { fn, "function" }, order = { order, "number", true } })
  providers[#providers + 1] = { fn = fn, order = order or 100 }
  table.sort(providers, function(a, b)
    return a.order < b.order
  end)
end

--- Remove every provider (re-setup and tests only).
function M.reset()
  providers = {}
end

--- Run every provider and return the joined section, or nil when nothing
--- contributed. A throwing provider is skipped with a warning so one broken
--- plugin cannot break every send.
function M.snapshot()
  local parts = {}
  for _, p in ipairs(providers) do
    local ok, text = pcall(p.fn)
    if not ok then
      vim.notify("yap: context provider failed: " .. tostring(text), vim.log.levels.WARN)
    elseif type(text) == "string" and text ~= "" then
      parts[#parts + 1] = text
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "\n\n")
end

-- ─── Built-in providers ─────────────────────────────────────────────────────

-- Git state for :pwd, or nil when it is not a git repo. A few cheap
-- synchronous calls; the result is capped so a dirty monorepo cannot flood
-- the prompt.
local function git_snapshot(cwd)
  local out = vim.fn.system({ "git", "-C", cwd, "status", "--porcelain", "--branch" })
  if vim.v.shell_error ~= 0 or out == "" then
    return nil
  end
  local head, changes = nil, {}
  for line in out:gmatch("[^\n]+") do
    if not head and line:sub(1, 3) == "## " then
      head = line:sub(4)
    elseif line ~= "" then
      changes[#changes + 1] = line:sub(4) -- strip the XY status + space
    end
  end
  if not head then
    return nil
  end

  -- fetch recent commits
  local recent_commits_out = vim.fn.system({ "git", "-C", cwd, "log", "-5", "--pretty=format:%h %s" })
  local recent_commits = {}
  if vim.v.shell_error == 0 and recent_commits_out ~= "" then
    for line in recent_commits_out:gmatch("[^\n]+") do
      recent_commits[#recent_commits + 1] = line
    end
  end

  -- fetch staged files
  local staged_out = vim.fn.system({ "git", "-C", cwd, "diff", "--cached", "--name-only" })
  local staged_files = {}
  if vim.v.shell_error == 0 and staged_out ~= "" then
    for line in staged_out:gmatch("[^\n]+") do
      staged_files[#staged_files + 1] = line
    end
  end

  local result_lines = {}
  if #changes == 0 then
    table.insert(result_lines, "Git: " .. head .. " (clean)")
  else
    local shown, max = {}, 12
    for i = 1, math.min(#changes, max) do
      shown[i] = changes[i]
    end
    if #changes > max then
      shown[#shown + 1] = ("+%d more"):format(#changes - max)
    end
    table.insert(result_lines, ("Git: %s, %d changed files: %s"):format(head, #changes, table.concat(shown, ", ")))
  end

  if #recent_commits > 0 then
    table.insert(result_lines, "Recent: " .. table.concat(recent_commits, " | "))
  end
  if #staged_files > 0 then
    local shown_staged, max_staged = {}, 12
    for i = 1, math.min(#staged_files, max_staged) do
      shown_staged[i] = staged_files[i]
    end
    if #staged_files > max_staged then
      shown_staged[#shown_staged + 1] = ("+%d more"):format(#staged_files - max_staged)
    end
    table.insert(result_lines, "Staged: " .. table.concat(shown_staged, ", "))
  end

  return table.concat(result_lines, "\n")
end

M.register(function()
  return "Current Neovim working directory: " .. vim.fn.getcwd()
end, 10)

M.register(function()
  return git_snapshot(vim.fn.getcwd())
end, 20)

return M
