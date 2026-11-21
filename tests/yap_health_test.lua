local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local health = require("harness.health")
local paths = require("harness.path")

yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })

--- collect() keyed by check name.
local function items()
  local m = {}
  for _, it in ipairs(health.collect()) do
    assert(type(it.name) == "string" and it.name ~= "", "health item without a name")
    assert(type(it.status) == "string", "health item without a status: " .. tostring(it.name))
    assert(type(it.lines) == "table" and #it.lines > 0, "health item without detail lines: " .. it.name)
    assert(m[it.name] == nil, "duplicate health item: " .. it.name)
    m[it.name] = it
  end
  return m
end

local function text(it)
  return table.concat(it.lines, "\n")
end

local function has(it, needle)
  return text(it):find(needle, 1, true) ~= nil
end

-- The entry point `:checkhealth harness` resolves: Neovim maps the name to
-- lua/**/harness/health.lua and calls require("harness.health").check().
assert(
  #vim.api.nvim_get_runtime_file("lua/harness/health.lua", false) == 1,
  "lua/harness/health.lua is not on the runtimepath"
)
assert(type(require("harness.health").check) == "function", "harness.health.check is missing")

-- This case starts from a first run. The suite writes a settings.json for the
-- case before the child starts, so remove it rather than depending on its
-- absence, and put it back (with our own content) below.
local settings = paths.config_home() .. "/yap/settings.json"
vim.fn.delete(settings)
assert(vim.fn.filereadable(settings) == 0, "could not remove the case's settings.json: " .. settings)

-- ── first run: no settings file ─────────────────────────────────────────────
local it = items()
assert(it["Neovim"].status == "ok", "Neovim: " .. text(it["Neovim"]))
assert(it["yap binary"].status == "ok", "yap binary: " .. text(it["yap binary"]))
assert(has(it["yap binary"], "built-in tools:"), "binary check did not list the tools: " .. text(it["yap binary"]))
assert(it["Provider settings"].status == "error", "a missing settings file must be an error")
assert(has(it["Provider settings"], "no settings file at"), "missing-file advice lacks the path")
assert(has(it["Provider settings"], "api_key_env"), "missing-file advice lacks a provider example")
assert(it["Model group"].status == "info", "model group without settings: " .. it["Model group"].status)
assert(it["MCP servers"].status == "info", "MCP without settings: " .. it["MCP servers"].status)
assert(it["Model cache"].status == "warn" or it["Model cache"].status == "ok", "model cache status")
-- Environment-dependent: assert shape, not the outcome.
assert(it["ripgrep"].lines[1] ~= "", "ripgrep check has no path/advice")
assert(
  it["bash sandbox"].status == "ok" or it["bash sandbox"].status == "warn",
  "sandbox status must be ok or warn: " .. it["bash sandbox"].status
)
assert(it["Session data"].status == "ok", "session data: " .. text(it["Session data"]))
assert(vim.fn.isdirectory(paths.sessions_root()) == 1, "the session root should be created by the check")

-- ── a configured provider ───────────────────────────────────────────────────
local cfgdir = vim.fn.fnamemodify(settings, ":h")
vim.fn.mkdir(cfgdir, "p")
vim.fn.writefile({
  '{"providers": {"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_HEALTH_KEY"}},'
    .. ' "mcp": {"echo": {"command": "true", "lazy": true}}}',
}, settings)
vim.env.YAP_HEALTH_KEY = "set"
it = items()
assert(it["Provider settings"].status == "ok", "provider: " .. text(it["Provider settings"]))
assert(has(it["Provider settings"], "mock: YAP_HEALTH_KEY is set"), "set key not reported")
assert(it["Model group"].status == "ok", "model group: " .. text(it["Model group"]))
assert(has(it["Model group"], "agent = mock/m1"), "model group does not name the combo")
assert(has(it["Model group"], "flash is unset"), "an empty flash group should be called out")
assert(it["MCP servers"].status == "ok", "MCP: " .. text(it["MCP servers"]))
assert(has(it["MCP servers"], "lazy"), "lazy MCP servers not called out")

-- An unset api_key_env is a warning, not an error: the file itself is fine.
vim.env.YAP_HEALTH_KEY = nil
it = items()
assert(it["Provider settings"].status == "warn", "unset key should warn")
assert(has(it["Provider settings"], "YAP_HEALTH_KEY is NOT set"), "unset key not reported")

-- A login provider needs no environment variable.
vim.fn.writefile({ '{"providers": {"chat": {"auth": "chatgpt"}}}' }, settings)
it = items()
assert(it["Provider settings"].status == "ok", "login provider: " .. text(it["Provider settings"]))
assert(has(it["Provider settings"], "chatgpt login"), "login provider not described")

-- The model group's provider must exist in the file.
vim.fn.writefile({ '{"providers": {"other": {"auth": "chatgpt"}}}' }, settings)
it = items()
assert(it["Model group"].status == "warn", "unconfigured provider should warn")
assert(has(it["Model group"], 'provider "mock" is not configured'), "unconfigured provider not named")

-- Invalid JSON is an error naming the file.
vim.fn.writefile({ "{ not json" }, settings)
it = items()
assert(it["Provider settings"].status == "error", "invalid JSON should error")
assert(has(it["Provider settings"], settings), "invalid-JSON advice lacks the path")

-- ── session directory permissions ───────────────────────────────────────────
vim.fn.delete(settings)
local root = paths.sessions_root()
local sdir = root .. "/proj/26-11/21-001"
vim.fn.mkdir(sdir, "p")
vim.fn.setfperm(sdir, "rwx------")
vim.fn.writefile({ "# @user", "hi" }, sdir .. "/session.md")
it = items()
assert(it["Session data"].status == "ok", "0700 session: " .. text(it["Session data"]))
assert(has(it["Session data"], "1 session(s) on disk"), "session count missing: " .. text(it["Session data"]))
vim.fn.setfperm(sdir, "rwxrwxrwx")
it = items()
assert(it["Session data"].status == "warn", "0777 session dir should warn")
assert(has(it["Session data"], "more permissive than 0700"), "permission advice missing")
vim.fn.setfperm(sdir, "rwx------")
assert(items()["Session data"].status == "ok", "restoring 0700 did not clear the warning")

-- ── a missing binary ────────────────────────────────────────────────────────
yap.config.bin = "/nonexistent/yap"
it = items()
assert(it["yap binary"].status == "error", "missing binary should error")
assert(has(it["yap binary"], "not found or not executable"), "missing binary advice is not actionable")
yap.config.bin = ROOT .. "/yap"
assert(items()["yap binary"].status == "ok", "restoring the binary did not recover")

-- ── rendering ───────────────────────────────────────────────────────────────
local saved = {
  start = vim.health.start,
  ok = vim.health.ok,
  warn = vim.health.warn,
  error = vim.health.error,
  info = vim.health.info,
}
local calls = {}
local function record(level)
  return function(msg)
    calls[#calls + 1] = { level = level, msg = msg }
  end
end
vim.health.start = record("start")
vim.health.ok = record("ok")
vim.health.warn = record("warn")
vim.health.error = record("error")
vim.health.info = record("info")
health.check()
vim.health.start = saved.start
vim.health.ok = saved.ok
vim.health.warn = saved.warn
vim.health.error = saved.error
vim.health.info = saved.info

assert(calls[1] and calls[1].level == "start" and calls[1].msg == "yap", "check() must start the yap report")
local levels, names = {}, {}
for _, c in ipairs(calls) do
  levels[c.level] = true
  local first = (c.msg or ""):match("^[^\n]+")
  names[first] = true
end
assert(levels.ok, "check() rendered no ok items")
assert(levels.warn or levels.error, "check() rendered no problems (expected the missing settings file)")
assert(names["Neovim"] and names["yap binary"] and names["Provider settings"], "check() dropped a section heading")

print("OK health checks: first-run advice, providers, model group, sessions, binary, render")
