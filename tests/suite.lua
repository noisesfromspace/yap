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
-- Cases are split into two tiers:
--
--   fast  deterministic and safe to run concurrently: pure-Lua buffer/fold/
--         winbar work, or a single quick turn on mock_fast. The full run
--         batches all fast cases into one parallel case (FAST_CONCURRENCY
--         children at once); this is what tests/fast.sh drives locally.
--   slow  timing-sensitive (stop/steer/follow/live-tool), multi-turn against
--         a latency-bearing mock, or subagent-spawning. These run as one
--         mini.test case each, in list order: a multi-turn timing budget no
--         longer races six other suites for the same mock, which is what made
--         the compact and fork cases flaky under the old parallel bash runner.
--
-- Selection is driven by two env vars (both default to "everything"):
--   YAP_TEST_TIER    "fast" | "slow"
--   YAP_TEST_FILTER  substring matched against the case name; when set, fast
--                    cases are registered individually so one can be targeted
--
-- Case fields:
--   name      the script: tests/<name>.lua
--   tier      "fast" or "slow" (see above)
--   port      port the mock provider listens on; the base_url in settings.json
--   mock      tests/<mock>.py to start first (nil: no provider traffic)
--   providers explicit name -> base_url map, for cases that pick a provider
local MiniTest = require("mini.test")

local TESTS = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local ROOT = vim.env.YAP_ROOT or vim.fn.fnamemodify(TESTS, ":h")

local CASES = {
  -- Sessions, transcript parsing and turn lifecycle against the streaming
  -- mocks. One port per mock server; a case that shares a mock shares it.
  { name = "yap_test", port = 18132, tier = "fast" },
  { name = "yap_attachment_test", port = 18132, tier = "fast" },
  { name = "yap_static_test", port = 18133, mock = "mock_fast.py", tier = "fast" },
  { name = "yap_session_usage_test", port = 18133, mock = "mock_fast.py", tier = "fast" },
  { name = "yap_session_events_test", port = 18133, mock = "mock_fast.py", tier = "fast" },
  { name = "yap_scratch_send_test", port = 18132, mock = "mock_slow.py", tier = "slow" },
  { name = "yap_scratch_flow_test", port = 18132, mock = "mock_slow.py", tier = "slow" },
  { name = "yap_scratch_template_test", port = 18132, tier = "fast" },
  { name = "yap_missing_bin_test", port = 18132, tier = "fast" },
  { name = "yap_health_test", port = 18132, tier = "fast" },
  { name = "yap_notify_test", port = 18133, mock = "mock_fast.py", tier = "fast" },
  { name = "yap_block_test", port = 18132, mock = "mock_slow.py", tier = "slow" },
  { name = "yap_toolparse_test", port = 18132, tier = "fast" },
  { name = "yap_prompt_blank_test", port = 18132, tier = "fast" },
  { name = "yap_close_session_test", port = 18142, mock = "mock_close.py", tier = "fast" },
  { name = "yap_close_sole_session_test", port = 18142, mock = "mock_close.py", tier = "fast" },
  { name = "yap_close_session_picker_test", port = 18142, mock = "mock_close.py", tier = "fast" },
  { name = "yap_e2e_livetool", port = 18141, mock = "mock_stream.py", tier = "slow" },
  { name = "yap_e2e_streamfold", port = 18135, mock = "mock_write.py", tier = "fast" },
  { name = "yap_audit_test", port = 18135, mock = "mock_write.py", tier = "fast" },
  { name = "yap_audit_rename_test", port = 18135, mock = "mock_write.py", tier = "fast" },
  { name = "yap_saveas_test", port = 18135, mock = "mock_write.py", tier = "fast" },
  { name = "yap_approval_inspect_test", port = 18162, mock = "mock_approval.py", tier = "fast" },
  { name = "yap_guard_auto_accept_test", port = 18163, mock = "mock_approval_safe.py", tier = "fast" },
  { name = "yap_approval_flow_test", port = 18132, tier = "fast" },
  { name = "yap_guard_keys_test", port = 18132, tier = "fast" },
  { name = "yap_guard_log_stack_test", port = 18132, tier = "fast" },
  { name = "yap_guard_close_test", port = 18132, tier = "fast" },
  { name = "yap_guard_clear_test", port = 18132, tier = "fast" },
  { name = "yap_guard_cap_test", port = 18132, tier = "fast" },
  { name = "yap_guard_focus_test", port = 18132, tier = "fast" },
  { name = "yap_follow_test", port = 18152, mock = "mock_follow.py", tier = "slow" },
  {
    name = "yap_picker_test",
    port = 18137,
    mock = "mock_models.py",
    tier = "fast",
    -- `yap models` list order: alpha answers from the mock, zeta is a dead
    -- endpoint so the listing has to merge a reachable and an unreachable
    -- provider.
    providers = {
      zeta = "http://127.0.0.1:19999/v1",
      alpha = "http://127.0.0.1:18137/v1",
    },
  },
  { name = "yap_describe_test", port = 18139, mock = "mock_describe.py", tier = "slow" },
  { name = "yap_eval_test", port = 18180, mock = "mock_eval.py", tier = "fast" },
  { name = "yap_steer_test", port = 18160, mock = "mock_steer.py", tier = "slow" },
  { name = "yap_stop_focus_test", port = 18160, mock = "mock_steer.py", tier = "slow" },
  { name = "yap_stop_draft_test", port = 18165, mock = "mock_stop_delay.py", tier = "slow" },
  { name = "yap_double_stop_test", port = 18166, mock = "mock_double_stop.py", tier = "slow" },
  { name = "yap_model_switch_test", port = 18170, mock = "mock_model_switch.py", tier = "slow" },
  { name = "yap_clear_queue_test", port = 18171, mock = "mock_clear_queue.py", tier = "slow" },
  { name = "yap_context_test", port = 18132, tier = "fast" },
  { name = "yap_session_path_test", port = 18132, tier = "fast" },
  { name = "yap_delete_test", port = 18132, tier = "fast" },
  { name = "yap_fork_test", port = 18164, mock = "mock_fork.py", tier = "slow" },
  { name = "yap_fork_shared_agents_test", port = 18132, tier = "fast" },
  { name = "yap_picker_tree_test", port = 18132, tier = "fast" },

  -- Buffer semantics, folds, winbar and parsing: no provider traffic.
  { name = "yap_fold_contract_test", port = 18132, tier = "fast" },
  { name = "yap_fold_test", port = 18132, tier = "fast" },
  { name = "yap_fold_frontmatter_test", port = 18132, tier = "fast" },
  { name = "yap_detailfold_test", port = 18132, tier = "fast" },
  { name = "yap_symbol_badges_test", port = 18132, tier = "fast" },
  { name = "yap_event_badges_test", port = 18132, tier = "fast" },
  { name = "yap_tool_duration_test", port = 18132, tier = "fast" },
  { name = "yap_tool_outcome_test", port = 18132, tier = "fast" },
  { name = "yap_fold_peek_test", port = 18132, tier = "fast" },
  { name = "yap_fold_za_test", port = 18132, tier = "fast" },
  { name = "yap_fold_reconcile_test", port = 18132, tier = "fast" },
  { name = "yap_fold_noflicker_test", port = 18132, tier = "fast" },
  { name = "yap_fold_leak_test", port = 18132, tier = "fast" },
  { name = "yap_fold_visual_test", port = 18132, tier = "fast" },
  { name = "yap_fold_mouse_test", port = 18132, tier = "fast" },
  { name = "yap_think_test", port = 18132, tier = "fast" },
  { name = "yap_error_test", port = 18132, tier = "fast" },
  { name = "yap_turn_positions_test", port = 18132, tier = "slow" },
  { name = "yap_ml_test", port = 18132, tier = "fast" },
  { name = "yap_streamfold_test", port = 18132, tier = "fast" },
  { name = "yap_marker_test", port = 18132, tier = "fast" },
  { name = "yap_model_test", port = 18132, tier = "fast" },
  { name = "yap_model_cache_test", port = 18132, tier = "fast" },
  { name = "yap_map_test", port = 18132, tier = "fast" },
  { name = "yap_keymap_test", port = 18132, tier = "fast" },
  { name = "yap_clear_test", port = 18132, tier = "fast" },
  { name = "yap_default_model_test", port = 18132, tier = "fast" },
  { name = "yap_live_open_test", port = 18132, tier = "fast" },
  { name = "yap_panel_edit_test", port = 18132, tier = "fast" },
  { name = "yap_leave_session_test", port = 18132, tier = "fast" },
  { name = "yap_uidiff_test", port = 18132, tier = "fast" },
  { name = "yap_fencefold_test", port = 18132, tier = "fast" },
  { name = "yap_fence_conformance_test", port = 18132, tier = "fast" },
  { name = "yap_transcript_conformance_test", port = 18132, tier = "fast" },
  { name = "yap_structure_test", port = 18132, tier = "fast" },
  { name = "yap_parse_incremental_test", port = 18132, tier = "fast" },
  { name = "yap_highlight_test", port = 18132, tier = "fast" },
  { name = "yap_lsp_test", port = 18132, tier = "fast" },
  { name = "yap_template_test", port = 18132, tier = "fast" },
  { name = "yap_frontmatter_test", port = 18132, tier = "fast" },
  { name = "yap_frontmatter_keys_test", port = 18132, tier = "fast" },
  { name = "yap_portable_session_test", port = 18132, tier = "fast" },
  { name = "yap_portable_discovery_test", port = 18132, tier = "fast" },
  { name = "yap_tools_test", port = 18132, tier = "fast" },
  { name = "yap_adopt_test", port = 18132, tier = "fast" },
  { name = "yap_textobj_test", port = 18132, tier = "fast" },
  { name = "yap_nav_test", port = 18132, tier = "fast" },
  { name = "yap_scratch_test", port = 18132, tier = "fast" },
  { name = "yap_session_preview_test", port = 18132, tier = "fast" },
  { name = "yap_winbar_resize_test", port = 18132, tier = "fast" },
  { name = "yap_winbar_fold_view_test", port = 18132, tier = "fast" },
  { name = "yap_winbar_ctx_test", port = 18132, tier = "fast" },
  { name = "yap_costguard_test", port = 18132, tier = "fast" },
  { name = "yap_winbar_steer_test", port = 18132, tier = "fast" },
  { name = "yap_redraw_test", port = 18132, tier = "fast" },
  { name = "yap_bd_test", port = 18132, tier = "fast" },
  { name = "yap_open_test", port = 18132, tier = "fast" },
  { name = "yap_encoding_test", port = 18132, tier = "fast" },
  { name = "yap_hide_save_test", port = 18132, tier = "fast" },
  { name = "yap_fcs_test", port = 18132, tier = "fast" },
  { name = "yap_help_test", port = 18132, tier = "fast" },
  { name = "yap_winfixbuf_test", port = 18132, tier = "fast" },
  { name = "yap_subagent_integration_test", port = 18132, tier = "slow" },
  { name = "yap_view_test", port = 18132, tier = "fast" },
  { name = "yap_tail_separator_test", port = 18132, tier = "fast" },
  { name = "yap_tail_follow_test", port = 18132, tier = "fast" },
  { name = "yap_tail_lifetime_test", port = 18132, tier = "fast" },

  -- A multi-turn stream on an 8s budget: last, so nothing else contends for
  -- the machine while it runs.
  { name = "yap_compact_test", port = 18132, mock = "mock_slow.py", tier = "slow" },
}

-- A mock's port is the server a case talks to. Two cases sharing a port with
-- different mocks would collide: the second mock's bind fails ("Address
-- already in use") and the case silently talks to the first mock, surfacing
-- much later as a confusing "mock did not start streaming" wait timeout. Catch
-- that here, before any case runs, so the failure names both mocks.
do
  local by_port = {}
  for _, case in ipairs(CASES) do
    if case.mock then
      local prev = by_port[case.port]
      if prev and prev ~= case.mock then
        error(
          ("mock port %d is shared by %s and %s; give each mock its own port"):format(case.port, prev, case.mock),
          0
        )
      end
      by_port[case.port] = case.mock
    end
  end
end

-- ---------------------------------------------------------------------------
-- Isolation
-- ---------------------------------------------------------------------------

-- Isolate the child's data dirs. HOME and XDG_* (state included: Neovim 0.13
-- keeps its log under stdpath('state')) pin sessions/config/cache/logs inside
-- the case dir. The NVIM_LOG_FILE vars are inherited from whatever Neovim runs
-- the suite, and nvim's startup check compares the inherited "want" path
-- against its own, then notifies WARN 100ms later when they differ — a
-- notification that races any test asserting on vim.notify.
local ENV_KEYS = { "HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME" }
local ENV_UNSET = { "NVIM_LOG_FILE", "__NVIM_LOG_FILE_WANT" }

local function isolate(dir)
  local saved = {}
  for _, key in ipairs(ENV_KEYS) do
    saved[key] = vim.env[key]
  end
  for _, key in ipairs(ENV_UNSET) do
    saved[key] = vim.env[key]
  end
  vim.env.HOME = dir
  vim.env.XDG_CONFIG_HOME = dir .. "/.config"
  vim.env.XDG_CACHE_HOME = dir .. "/.cache"
  vim.env.XDG_STATE_HOME = dir .. "/.local/state"
  for _, key in ipairs(ENV_UNSET) do
    vim.env[key] = nil
  end
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

-- The file-backed clipboard: a headless runner (no $DISPLAY/$WAYLAND_DISPLAY)
-- has no clipboard provider, so the `+`/`*` registers silently no-op and any
-- test asserting a clipboard copy fails. Back them with a per-case file so
-- clipboard copies are testable everywhere.
local CLIP_LUA =
  "vim.g.clipboard = { name = 'yap-test', copy = { ['+'] = 'tee %s', ['*'] = 'tee %s' }, paste = { ['+'] = 'cat %s', ['*'] = 'cat %s' }, cache_enabled = 0 }"

--- Set up a case's isolated dir, config and mock, and spawn its child Neovim.
--- The child inherits the isolated env at spawn (isolate/un-isolate only wraps
--- child.start), so several children can each hold their own $HOME at once.
--- Does not run the test: `run` and `run_async` do that, serially or not.
local function spawn(case)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.config", "p")
  write_config(case, dir)
  start_mock(case)

  local child = MiniTest.new_child_neovim()
  local saved = isolate(dir)
  local ok, err = pcall(function()
    child.start({ "--cmd", "set rtp^=" .. ROOT })
    local clip = dir .. "/clipboard.txt"
    child.lua(CLIP_LUA:format(clip, clip, clip, clip))
  end)
  unisolate(saved)

  return {
    name = case.name,
    script = TESTS .. "/" .. case.name .. ".lua",
    dir = dir,
    child = child,
    ok = ok,
    err = err,
  }
end

--- Run one case serially: the child's RPC error already carries the failing
--- assertion's traceback, which `error` re-raises with the session dir.
local function run(case)
  local e = spawn(case)
  local err = e.err
  if e.ok then
    local ok, serr = pcall(function()
      e.child.lua(("dofile(%q)"):format(e.script))
    end)
    if not ok then
      err = serr
    end
  end
  pcall(e.child.stop)
  if err then
    error(("%s\n\n(session home kept at %s)"):format(err, e.dir), 0)
  end
  vim.fn.delete(e.dir, "rf")
end

--- Start a child's test without blocking (the parallel batch), recording the
--- result in vim.g for `await` to collect. xpcall + debug.traceback keeps the
--- failure traceback that the RPC error would otherwise carry.
local function run_async(e)
  e.child.lua_notify(
    ("local ok, err = xpcall(function() dofile(%q) end, function(msg) return debug.traceback(msg, 2) end); vim.g.yap_test_ok = ok; vim.g.yap_test_err = ok and '' or tostring(err)")
      :format(e.script)
  )
end

--- Block until a spawned child's test finishes, then stop it and report. The
--- blocking lua_get waits for the queued dofile to complete (requests are
--- ordered on the channel), while other children keep running in their own
--- processes.
local function await(e)
  local err = e.err
  if e.ok then
    local ok, res = pcall(function()
      return e.child.lua_get("vim.g.yap_test_ok")
    end)
    if not ok then
      err = res
    elseif res == false then
      local ok2, serr = pcall(function()
        return e.child.lua_get("vim.g.yap_test_err")
      end)
      err = ok2 and serr or "child failed without a message"
    end
  end
  pcall(e.child.stop)
  if err then
    return ("%s:\n%s\n\n(session home kept at %s)"):format(e.name, err, e.dir)
  end
  vim.fn.delete(e.dir, "rf")
  return nil
end

--- Run the fast tier as a bounded fan-out of child Neovims. Fail-fast in the
--- sense that the first failure is what surfaces, but every case still runs.
local function run_pool(cases, concurrency)
  local next_i, active, first_err = 1, {}, nil
  local function fill()
    while next_i <= #cases and #active < concurrency do
      local e = spawn(cases[next_i])
      next_i = next_i + 1
      if e.ok then
        run_async(e)
      end
      active[#active + 1] = e
    end
  end
  fill()
  while #active > 0 do
    local e = table.remove(active, 1)
    local err = await(e)
    if err and not first_err then
      first_err = err
    end
    fill()
  end
  if first_err then
    error(first_err, 0)
  end
end

-- ---------------------------------------------------------------------------
-- Tier selection and registration
-- ---------------------------------------------------------------------------

-- Fan-out for the parallel fast batch. Fast cases are mostly cheap child
-- startups, so the win plateaus around this many concurrent children.
local FAST_CONCURRENCY = 8

local tier = vim.env.YAP_TEST_TIER or ""
local name_filter = vim.env.YAP_TEST_FILTER or ""

local function selected(case)
  if tier ~= "" and case.tier ~= tier then
    return false
  end
  return name_filter == "" or case.name:find(name_filter, 1, true) ~= nil
end

local fast, slow = {}, {}
for _, case in ipairs(CASES) do
  if selected(case) then
    if case.tier == "fast" then
      fast[#fast + 1] = case
    else
      slow[#slow + 1] = case
    end
  end
end

-- A backstop for an aborted run (:cquit from the reporter, :cq, an error in
-- the runner): post_once alone would leave the servers behind.
vim.api.nvim_create_autocmd("VimLeavePre", { callback = stop_mocks })

local T = MiniTest.new_set({
  hooks = {
    post_once = stop_mocks,
  },
})

-- Slow tier: one mini.test case per file so a failure names the case and keeps
-- its session dir. mini.test runs cases in list order (serially).
for _, case in ipairs(slow) do
  T[case.name] = function()
    run(case)
  end
end

-- Fast tier: the full run batches every fast case into one parallel case; a
-- name-filtered run registers them individually so one case can be targeted
-- and reports on its own.
if name_filter ~= "" then
  for _, case in ipairs(fast) do
    T[case.name] = function()
      run(case)
    end
  end
elseif #fast > 0 then
  T.fast_batch = function()
    run_pool(fast, FAST_CONCURRENCY)
  end
end

return T
