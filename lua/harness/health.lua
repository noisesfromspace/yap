-- :checkhealth harness — diagnose the environment yap runs in: the editor, the
-- backend binary, provider settings, ripgrep, the bubblewrap sandbox, the
-- session data root, the model group and the model cache.
--
-- collect() returns structured items ({ name, status, lines }) so the checks
-- are testable without parsing rendered output; check() renders them through
-- vim.health. lua/harness/health.lua is the entry point :checkhealth discovers.
--
-- Every check reads only what the plugin itself reads (config.defaults,
-- harness.path, the settings file) and stays fast: the two subprocess probes
-- (`yap tools`, `bwrap … true`) have explicit timeouts, and the session walk
-- is the same one the picker uses.

local M = {}

local paths = require("harness.path")

--- One check result: a check name, a vim.health status, and detail lines.
local function item(name, status, lines)
  return { name = name, status = status, lines = lines or {} }
end

--- The Go backend's settings file: the same $XDG_CONFIG_HOME/yap/settings.json
--- resolution configPath() uses in agent/config/config.go.
local function settings_file()
  return paths.config_home() .. "/yap/settings.json"
end

-- Parsed settings.json, memoized for one collect() pass so the provider,
-- model-group, sandbox and MCP checks share one read. `err` is "missing",
-- "invalid", or nil.
local cached_path, cached_cfg, cached_err, cached_done

local function settings()
  if not cached_done then
    cached_done = true
    cached_path, cached_cfg, cached_err = settings_file(), nil, nil
    local f = io.open(cached_path, "r")
    if not f then
      cached_err = "missing"
    else
      local ok, decoded = pcall(vim.json.decode, f:read("*a") or "")
      f:close()
      if not ok or type(decoded) ~= "table" then
        cached_err = "invalid"
      else
        cached_cfg = decoded
      end
    end
  end
  return cached_path, cached_cfg, cached_err
end

--- A compact "how long ago" for cache age: 30s, 12m, 5h, 3d.
local function ago(sec)
  if sec < 90 then
    return math.max(sec, 0) .. "s"
  elseif sec < 5400 then
    return math.floor(sec / 60) .. "m"
  elseif sec < 172800 then
    return math.floor(sec / 3600) .. "h"
  end
  return math.floor(sec / 86400) .. "d"
end

-- ─── checks ────────────────────────────────────────────────────────────────

local function check_nvim()
  local v = vim.version()
  local version = string.format("%d.%d.%d", v.major, v.minor, v.patch)
  if vim.fn.has("nvim-0.11") == 1 then
    return item("Neovim", "ok", { "version " .. version })
  end
  return item("Neovim", "error", {
    "version " .. version .. " is too old; yap needs 0.11 or newer",
    "Folding, the winbar and the LSP client rely on 0.11 APIs.",
  })
end

local function check_binary()
  local name = "yap binary"
  local bin = require("harness").config.bin
  if type(bin) ~= "string" or bin == "" then
    return item(name, "error", {
      "config.bin is empty",
      'Point yap at the backend: require("harness").setup({ bin = "/path/to/yap" })',
    })
  end
  if vim.fn.executable(bin) ~= 1 then
    return item(name, "error", {
      "not found or not executable: " .. bin,
      "Build it: CGO_ENABLED=0 go build -o ~/.local/bin/yap ./agent",
      'Or set the path: require("harness").setup({ bin = "/path/to/yap" })',
    })
  end
  local path = vim.fn.exepath(bin)
  if path == "" then
    path = bin
  end
  -- `yap tools` is the cheapest round trip that proves the binary runs; it
  -- needs no config and no network.
  local ok, res = pcall(function()
    return vim.system({ bin, "tools" }, { text = true }):wait(10000)
  end)
  if not ok then
    return item(name, "error", { "could not run " .. bin .. ": " .. tostring(res) })
  end
  if res.code ~= 0 then
    local lines = { string.format("%s: `yap tools` exited %d", path, res.code) }
    local stderr = (res.stderr or ""):gsub("%s+$", "")
    if stderr ~= "" then
      lines[#lines + 1] = stderr
    end
    return item(name, "error", lines)
  end
  local tools = {}
  for _, line in ipairs(vim.split((res.stdout or ""):gsub("%s+$", ""), "\n")) do
    if line ~= "" then
      tools[#tools + 1] = line
    end
  end
  return item(name, "ok", {
    path,
    string.format("%d built-in tools: %s", #tools, table.concat(tools, ", ")),
  })
end

local function check_settings()
  local name = "Provider settings"
  local path, cfg, err = settings()
  if err == "missing" then
    return item(name, "error", {
      "no settings file at " .. path,
      "Create it with at least one provider, for example:",
      '  { "providers": { "openai": { "api_key_env": "OPENAI_API_KEY" } } }',
      "Then export that variable and pick a model with <leader>m.",
      "See :help yap-configuration.",
    })
  elseif err then
    return item(name, "error", {
      path .. " is not valid JSON",
      "See :help yap-configuration for the accepted shape.",
    })
  end
  local providers = type(cfg.providers) == "table" and cfg.providers or {}
  local names = {}
  for n in pairs(providers) do
    names[#names + 1] = n
  end
  table.sort(names)
  if #names == 0 then
    return item(name, "error", {
      path .. " configures no providers",
      'Add one, e.g. "providers": { "openai": { "api_key_env": "OPENAI_API_KEY" } }',
      "See :help yap-configuration.",
    })
  end
  local lines = { path, string.format("%d provider(s): %s", #names, table.concat(names, ", ")) }
  local missing = {}
  for _, n in ipairs(names) do
    local p = providers[n]
    if type(p) ~= "table" then
      lines[#lines + 1] = n .. ": malformed entry (expected an object)"
      missing[#missing + 1] = n
    elseif type(p.auth) == "string" and p.auth ~= "" then
      lines[#lines + 1] = string.format("%s: %s login", n, p.auth)
    elseif type(p.api_key_env) == "string" and p.api_key_env ~= "" then
      local value = vim.env[p.api_key_env]
      if value and value ~= "" then
        lines[#lines + 1] = string.format("%s: %s is set", n, p.api_key_env)
      else
        lines[#lines + 1] = string.format("%s: %s is NOT set", n, p.api_key_env)
        missing[#missing + 1] = n
      end
    else
      lines[#lines + 1] = string.format("%s: no credential (set api_key_env or auth)", n)
      missing[#missing + 1] = n
    end
  end
  if #missing > 0 then
    return item(name, "warn", lines)
  end
  return item(name, "ok", lines)
end

local function check_model_groups()
  local name = "Model group"
  local groups = require("harness").config.model_groups or {}
  local agent = groups.agent
  if type(agent) ~= "string" or agent == "" then
    return item(name, "error", {
      "model_groups.agent is not set, so a new session has no model",
      'require("harness").setup({ model_groups = { agent = "openai/gpt-6.1-sol" } })',
      "See :help yap-models.",
    })
  end
  local provider = agent:match("^([%w_.:%-]+)/")
  if not provider then
    return item(name, "warn", {
      "model_groups.agent = " .. agent .. " is not a provider/model combo",
      "See :help yap-models.",
    })
  end
  local lines = { "agent = " .. agent }
  local flash = groups.flash
  if type(flash) == "string" and flash ~= "" then
    lines[#lines + 1] = "flash = " .. flash
  else
    lines[#lines + 1] = "flash is unset: no session descriptions, and :YapEval! uses agent"
  end
  -- The combo's provider must exist in settings.json, or the first send fails
  -- with a provider-not-configured error.
  local _, cfg, err = settings()
  if err then
    lines[#lines + 1] = "provider cannot be verified: no readable settings file"
    return item(name, "info", lines)
  end
  if type(cfg.providers) == "table" and cfg.providers[provider] == nil then
    lines[#lines + 1] = string.format("provider %q is not configured in %s", provider, settings_file())
    return item(name, "warn", lines)
  end
  return item(name, "ok", lines)
end

local function check_rg()
  local name = "ripgrep"
  if vim.fn.executable("rg") ~= 1 then
    return item(name, "error", {
      "rg is not on PATH",
      "The search, glob and sessions tools need ripgrep; install it.",
    })
  end
  local ok, res = pcall(function()
    return vim.system({ "rg", "--version" }, { text = true }):wait(5000)
  end)
  local first = ""
  if ok and res.stdout then
    first = vim.split(res.stdout, "\n")[1] or ""
  end
  return item(name, "ok", { vim.fn.exepath("rg"), first })
end

local function check_sandbox()
  local name = "bash sandbox"
  local _, cfg, err = settings()
  local sandbox = not err and type(cfg.sandbox) == "table" and cfg.sandbox or {}
  if sandbox.enabled == false then
    return item(name, "warn", {
      'disabled in settings.json ("sandbox": { "enabled": false })',
      "bash runs with the full write access of your user account.",
    })
  end
  local sysname = vim.uv.os_uname().sysname
  if sysname ~= "Linux" then
    return item(name, "warn", {
      "bash runs UNSANDBOXED on " .. sysname .. " (the sandbox is Linux-only)",
      "Destructive commands and secret paths still pause for approval.",
    })
  end
  if vim.fn.executable("bwrap") ~= 1 then
    return item(name, "warn", {
      "bwrap is not on PATH, so bash runs UNSANDBOXED",
      "Install bubblewrap for the read-only filesystem barrier.",
    })
  end
  -- The same probe safety.SandboxActive runs: bwrap can create the namespaces
  -- and enforce a read-only root. A failure here silently disables the
  -- sandbox for every turn, so it deserves a warning of its own.
  local ok, res = pcall(function()
    return vim
      .system({ "bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--", "true" }, { text = true })
      :wait(15000)
  end)
  if not ok then
    return item(name, "warn", { "could not run bwrap: " .. tostring(res), "bash runs UNSANDBOXED." })
  end
  if res.code ~= 0 then
    local lines = {
      "bwrap is installed but cannot create namespaces, so bash runs UNSANDBOXED",
    }
    local stderr = (res.stderr or ""):gsub("%s+$", "")
    if stderr ~= "" then
      lines[#lines + 1] = stderr
    end
    lines[#lines + 1] = "Some kernels disable unprivileged user namespaces; enable them or accept the fallback."
    return item(name, "warn", lines)
  end
  local lines = {
    "bubblewrap is active: the filesystem is read-only outside the writable allowlist",
    "writable: the project cwd, the session assets dir, the Go/Nix build caches, sandbox.allow_write",
  }
  if type(sandbox.allow_write) == "table" and #sandbox.allow_write > 0 then
    lines[#lines + 1] = "allow_write: " .. table.concat(sandbox.allow_write, ", ")
  end
  if type(sandbox.deny_read) == "table" and #sandbox.deny_read > 0 then
    lines[#lines + 1] = "deny_read: " .. table.concat(sandbox.deny_read, ", ")
  end
  return item(name, "ok", lines)
end

local function check_sessions()
  local name = "Session data"
  local ok, root = pcall(paths.sessions_root)
  if not ok then
    return item(name, "error", { tostring(root) })
  end
  local st = vim.uv.fs_stat(root)
  if not st or st.type ~= "directory" then
    vim.v.errmsg = ""
    local made = pcall(vim.fn.mkdir, root, "p")
    if not made or vim.fn.isdirectory(root) ~= 1 then
      local lines = { root .. " does not exist and cannot be created" }
      local errmsg = vim.v.errmsg
      if type(errmsg) == "string" and errmsg ~= "" then
        lines[#lines + 1] = errmsg
      end
      lines[#lines + 1] = "Check the permissions on the parent directory, or set sessions_dir in setup()."
      return item(name, "error", lines)
    end
    return item(name, "ok", { root, "created now; the first session is written here" })
  end
  if vim.fn.filewritable(root) ~= 2 then
    return item(name, "error", { root .. " is not writable", "Check ownership and permissions." })
  end
  -- Transcripts, notes and audit logs can contain secrets, so yap creates
  -- *session* directories 0700. The root itself holds only project slugs, so
  -- it is reported, not warned on; a world-readable session directory is the
  -- condition that actually leaks a conversation.
  local ok_sessions, sessions = pcall(paths.session_dirs, root)
  local root_perms = st.mode % 512
  local lines = { root, string.format("root mode %03o", root_perms) }
  if ok_sessions then
    lines[#lines + 1] = string.format("%d session(s) on disk", #sessions)
    local checked, leaks = 0, {}
    for _, dir in ipairs(sessions) do
      if checked == 50 then
        break
      end
      local dst = vim.uv.fs_stat(dir)
      if dst then
        checked = checked + 1
        local perms = dst.mode % 512
        if perms % 8 ~= 0 or math.floor(perms / 8) % 8 ~= 0 then
          leaks[#leaks + 1] = string.format("%s (mode %03o)", dir, perms)
        end
      end
    end
    if #leaks > 0 then
      lines[#lines + 1] =
        string.format("%d of %d sampled session dir(s) are more permissive than 0700:", #leaks, checked)
      for _, l in ipairs(leaks) do
        if #lines >= 10 then
          lines[#lines + 1] = "  …"
          break
        end
        lines[#lines + 1] = "  " .. l
      end
      lines[#lines + 1] = "Transcripts and audit logs can contain secrets; run chmod 700 on them."
      return item(name, "warn", lines)
    end
  end
  return item(name, "ok", lines)
end

local function check_model_cache()
  local name = "Model cache"
  local config = require("harness.config")
  local path = config.models_cache_path()
  local st = vim.uv.fs_stat(path)
  if not st then
    return item(name, "warn", {
      "not populated yet at " .. path,
      "It fills during setup() from `yap models`; <leader>m refreshes it.",
    })
  end
  local combos = 0
  for _, line in ipairs(vim.fn.readfile(path)) do
    if line ~= "" then
      combos = combos + 1
    end
  end
  local age = os.time() - ((st.mtime and st.mtime.sec) or 0)
  local lines = { string.format("%s (%d combos, updated %s ago)", path, combos, ago(age)) }
  if age > 7 * 86400 then
    lines[#lines + 1] = "Stale: a provider added since then is missing until the next refresh."
    return item(name, "warn", lines)
  end
  return item(name, "ok", lines)
end

local function check_mcp()
  local name = "MCP servers"
  local _, cfg, err = settings()
  if err then
    return item(name, "info", { "skipped: no readable settings file" })
  end
  local servers = type(cfg.mcp) == "table" and cfg.mcp or {}
  local names = {}
  for n in pairs(servers) do
    names[#names + 1] = n
  end
  table.sort(names)
  if #names == 0 then
    return item(name, "info", { "none configured; MCP is optional" })
  end
  local lines = { string.format("%d configured: %s", #names, table.concat(names, ", ")) }
  local lazy = {}
  for _, n in ipairs(names) do
    if type(servers[n]) == "table" and servers[n].lazy == true then
      lazy[#lazy + 1] = n
    end
  end
  if #lazy > 0 then
    lines[#lines + 1] = "lazy (tools load on first use): " .. table.concat(lazy, ", ")
  end
  return item(name, "ok", lines)
end

-- ─── entry points ──────────────────────────────────────────────────────────

--- Every check, in report order, as { name, status, lines } items. Status is
--- a vim.health level: "ok", "warn", "error" or "info". A check that raises is
--- reported as an error rather than aborting the whole report.
function M.collect()
  cached_done = false
  local checks = {
    { "Neovim", check_nvim },
    { "yap binary", check_binary },
    { "Provider settings", check_settings },
    { "Model group", check_model_groups },
    { "ripgrep", check_rg },
    { "bash sandbox", check_sandbox },
    { "Session data", check_sessions },
    { "Model cache", check_model_cache },
    { "MCP servers", check_mcp },
  }
  local out = {}
  for _, c in ipairs(checks) do
    local ok, res = pcall(c[2])
    if not ok then
      res = item(c[1], "error", { "check failed: " .. tostring(res) })
    end
    out[#out + 1] = res
  end
  cached_done = false
  return out
end

--- Render the checks for `:checkhealth harness`.
function M.check()
  local health = vim.health
  health.start("yap")
  for _, it in ipairs(M.collect()) do
    local render = health[it.status] or health.info
    render(it.name .. "\n" .. table.concat(it.lines, "\n"))
  end
end

return M
