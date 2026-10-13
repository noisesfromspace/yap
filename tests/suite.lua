-- The yap Lua suite, as mini.test cases. Entry point: tests/minitest.lua.
--
-- Every case runs one tests/<script>.lua in its own child Neovim process with
-- its own $HOME, $XDG_CONFIG_HOME and $XDG_CACHE_HOME, so session files, audit
-- logs, the scratch queue and the mock provider config cannot bleed between
-- tests — and a case that leaves global state (autocmds, buffer vars, an open
-- session) behind cannot affect the next one. Mock providers (tests/mock_*.py)
-- are started on demand, one server per mock:port, and stopped when the run
-- ends.
--
-- Cases run in list order, sequentially: a multi-turn timing budget no longer
-- races six other suites for the same mock, which is what made the compact and
-- fork cases flaky under the old parallel bash runner.
--
-- Case fields:
--   name      the script: tests/<name>.lua
--   port      port the mock provider listens on; the base_url in settings.json
--   mock      tests/<mock>.py to start first (nil: no provider traffic)
--   providers explicit name -> base_url map, for cases that pick a provider
local MiniTest = require("mini.test")

local TESTS = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local ROOT = vim.env.YAP_ROOT or vim.fn.fnamemodify(TESTS, ":h")

local CASES = {
  -- Sessions, transcript parsing and turn lifecycle against the streaming
  -- mocks. One port per mock server; a case that shares a mock shares it.
  { name = "yap_test", port = 18132, mock = "mock_slow.py" },
  { name = "yap_attachment_test", port = 18132, mock = "mock_slow.py" },
  { name = "yap_static_test", port = 18132, mock = "mock_slow.py" },
  { name = "yap_session_usage_test", port = 18132, mock = "mock_slow.py" },
  { name = "yap_scratch_send_test", port = 18132, mock = "mock_slow.py" },
  { name = "yap_notify_test", port = 18132, mock = "mock_slow.py" },
  { name = "yap_block_test", port = 18132, mock = "mock_slow.py" },
  { name = "yap_toolparse_test", port = 18133, mock = "mock_tool.py" },
  { name = "yap_close_session_test", port = 18142, mock = "mock_close.py" },
  { name = "yap_close_session_picker_test", port = 18142, mock = "mock_close.py" },
  { name = "yap_e2e_livetool", port = 18141, mock = "mock_stream.py" },
  { name = "yap_e2e_streamfold", port = 18135, mock = "mock_write.py" },
  { name = "yap_audit_test", port = 18135, mock = "mock_write.py" },
  { name = "yap_audit_rename_test", port = 18135, mock = "mock_write.py" },
  { name = "yap_saveas_test", port = 18135, mock = "mock_write.py" },
  { name = "yap_approval_inspect_test", port = 18162, mock = "mock_approval.py" },
  { name = "yap_approval_flow_test", port = 18132 },
  { name = "yap_guard_keys_test", port = 18132 },
  { name = "yap_guard_close_test", port = 18132 },
  { name = "yap_guard_cap_test", port = 18132 },
  { name = "yap_follow_test", port = 18152, mock = "mock_follow.py" },
  {
    name = "yap_picker_test",
    port = 18137,
    mock = "mock_models.py",
    -- `yap models` list order: alpha answers from the mock, zeta is a dead
    -- endpoint so the listing has to merge a reachable and an unreachable
    -- provider.
    providers = {
      zeta = "http://127.0.0.1:19999/v1",
      alpha = "http://127.0.0.1:18137/v1",
    },
  },
  { name = "yap_describe_test", port = 18139, mock = "mock_describe.py" },
  { name = "yap_steer_test", port = 18160, mock = "mock_steer.py" },
  { name = "yap_model_switch_test", port = 18170, mock = "mock_model_switch.py" },
  { name = "yap_cwd_test", port = 18132 },
  { name = "yap_git_test", port = 18132 },
  { name = "yap_fork_test", port = 18163, mock = "mock_fork.py" },

  -- Buffer semantics, folds, winbar and parsing: no provider traffic.
  { name = "yap_fold_contract_test", port = 18132 },
  { name = "yap_fold_test", port = 18132 },
  { name = "yap_detailfold_test", port = 18132 },
  { name = "yap_fold_peek_test", port = 18132 },
  { name = "yap_fold_za_test", port = 18132 },
  { name = "yap_fold_reconcile_test", port = 18132 },
  { name = "yap_fold_noflicker_test", port = 18132 },
  { name = "yap_fold_leak_test", port = 18132 },
  { name = "yap_fold_mouse_test", port = 18132 },
  { name = "yap_think_test", port = 18132 },
  { name = "yap_error_test", port = 18132 },
  { name = "yap_ml_test", port = 18132 },
  { name = "yap_streamfold_test", port = 18132 },
  { name = "yap_marker_test", port = 18132 },
  { name = "yap_model_test", port = 18132 },
  { name = "yap_model_cache_test", port = 18132 },
  { name = "yap_map_test", port = 18132 },
  { name = "yap_keymap_test", port = 18132 },
  { name = "yap_file_picker_test", port = 18132 },
  { name = "yap_clear_test", port = 18132 },
  { name = "yap_default_model_test", port = 18132 },
  { name = "yap_live_open_test", port = 18132 },
  { name = "yap_leave_session_test", port = 18132 },
  { name = "yap_uidiff_test", port = 18132 },
  { name = "yap_fencefold_test", port = 18132 },
  { name = "yap_fence_conformance_test", port = 18132 },
  { name = "yap_lsp_test", port = 18132 },
  { name = "yap_template_test", port = 18132 },
  { name = "yap_frontmatter_test", port = 18132 },
  { name = "yap_knobs_test", port = 18132 },
  { name = "yap_tools_test", port = 18132 },
  { name = "yap_adopt_test", port = 18132 },
  { name = "yap_alerts_test", port = 18132 },
  { name = "yap_textobj_test", port = 18132 },
  { name = "yap_nav_test", port = 18132 },
  { name = "yap_scratch_test", port = 18132 },
  { name = "yap_session_preview_test", port = 18132 },
  { name = "yap_winbar_resize_test", port = 18132 },
  { name = "yap_winbar_fold_view_test", port = 18132 },
  { name = "yap_winbar_ctx_test", port = 18132 },
  { name = "yap_winbar_steer_test", port = 18132 },
  { name = "yap_bd_test", port = 18132 },
  { name = "yap_open_test", port = 18132 },
  { name = "yap_encoding_test", port = 18132 },
  { name = "yap_hide_save_test", port = 18132 },
  { name = "yap_fcs_test", port = 18132 },
  { name = "yap_help_test", port = 18132 },
  { name = "yap_winfixbuf_test", port = 18132 },
  { name = "yap_subagent_integration_test", port = 18132 },
  { name = "yap_view_test", port = 18132 },
  { name = "yap_tail_separator_test", port = 18132 },

  -- A multi-turn stream on an 8s budget: last, so nothing else contends for
  -- the machine while it runs.
  { name = "yap_compact_test", port = 18132, mock = "mock_slow.py" },
}

-- ---------------------------------------------------------------------------
-- Isolation
-- ---------------------------------------------------------------------------

local ENV_KEYS = { "HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME" }

local function isolate(dir)
  local saved = {}
  for _, key in ipairs(ENV_KEYS) do
    saved[key] = vim.env[key]
  end
  vim.env.HOME = dir
  vim.env.XDG_CONFIG_HOME = dir .. "/.config"
  vim.env.XDG_CACHE_HOME = dir .. "/.cache"
  return saved
end

local function unisolate(saved)
  for key, value in pairs(saved) do
    vim.env[key] = value
  end
end

--- The provider config the spawned agent binary reads. Written before the
--- child starts: the child inherits these env vars, and so does any `yap`
--- process it spawns.
local function write_config(case, dir)
  local providers = {}
  if case.providers then
    for name, url in pairs(case.providers) do
      providers[name] = { base_url = url, api_key_env = "MOONSHOT_API_KEY" }
    end
  else
    providers.mock = { base_url = "http://127.0.0.1:" .. case.port .. "/v1", api_key_env = "MOONSHOT_API_KEY" }
  end
  local config = {
    providers = providers,
    pricing = { m1 = { input = 2.0, output = 10.0 } },
  }
  vim.fn.mkdir(dir .. "/.config/yap", "p")
  vim.fn.writefile({ vim.json.encode(config) }, dir .. "/.config/yap/settings.json")
end

-- ---------------------------------------------------------------------------
-- Mock providers
-- ---------------------------------------------------------------------------

local mocks = {}

--- True while a server accepts connections on the port. Probed
--- synchronously: a `vim.uv` connect callback never completes inside
--- mini.test's executor, so the readiness check cannot depend on it.
local function port_open(port)
  vim.fn.system({ "bash", "-c", ("exec 3<>/dev/tcp/127.0.0.1/%d"):format(port) })
  return vim.v.shell_error == 0
end

--- Start the case's mock server unless its mock:port is already up. Waits for
--- the socket to accept instead of sleeping a fixed amount.
local function start_mock(case)
  if not case.mock then
    return
  end
  local key = case.mock .. ":" .. case.port
  if mocks[key] then
    return
  end
  local failure = nil
  mocks[key] = vim.system({ "python3", TESTS .. "/" .. case.mock }, { cwd = ROOT }, function(res)
    failure = (res.stderr or "") .. (res.stdout or "")
  end)
  -- Poll with a blocking sleep, not vim.wait: a case runs inside mini.test's
  -- own executor loop, where a nested vim.wait is not driven at the requested
  -- interval (the condition gets polled every ~700ms instead of every 20ms).
  local deadline = vim.uv.now() + 5000
  while not port_open(case.port) do
    if vim.uv.now() > deadline then
      error(("mock %s did not listen on port %d\n%s"):format(case.mock, case.port, failure or "(still running)"), 0)
    end
    vim.uv.sleep(20)
  end
end

local function stop_mocks()
  for _, handle in pairs(mocks) do
    pcall(function()
      handle:kill("sigterm")
    end)
  end
  mocks = {}
end

-- ---------------------------------------------------------------------------
-- Cases
-- ---------------------------------------------------------------------------

local function run(case)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.config", "p")
  write_config(case, dir)
  start_mock(case)

  local child = MiniTest.new_child_neovim()
  local saved = isolate(dir)
  local ok, err = pcall(function()
    child.start({ "--cmd", "set rtp^=" .. ROOT })
    child.lua(("dofile(%q)"):format(TESTS .. "/" .. case.name .. ".lua"))
  end)
  pcall(child.stop)
  unisolate(saved)

  if ok then
    vim.fn.delete(dir, "rf")
    return
  end
  -- Keep a failing case's home directory: it holds the session files, audit
  -- logs and live tail the assertion was looking at.
  error(("%s\n\n(session home kept at %s)"):format(err, dir), 0)
end

-- A backstop for an aborted run (:cquit from the reporter, :cq, an error in
-- the runner): post_once alone would leave the servers behind.
vim.api.nvim_create_autocmd("VimLeavePre", { callback = stop_mocks })

local T = MiniTest.new_set({
  hooks = {
    post_once = stop_mocks,
  },
})
for _, case in ipairs(CASES) do
  T[case.name] = function()
    run(case)
  end
end

return T
