-- yap configuration: the defaults table, provider/model discovery and the
-- persisted default combo. Everything else reads the live table through
-- `require("harness").config` (which init.lua points at M.defaults), so a
-- setup() call extends this table in place and every reader sees it.

local M = {}

local paths = require("harness.path")

M.defaults = {
  bin = "yap", -- path to the yap binary
  provider = "anthropic",
  model = "claude-sonnet-5-5",
  -- Default active reasoning level, seeded into a new session's frontmatter
  -- as `reasoning_level` so it is visible and hand-editable from the first
  -- line. Delete the line in a session (or set the default to nil) to fall
  -- back to the provider's own default.
  reasoning_level = "medium",
  -- Optional override list of "provider/model" combos for
  -- :YapChangeModel. When unset, the picker queries every provider
  -- in config.json for its model list (GET /models).
  models = nil,
  -- System prompt for new buffers: read from agents_file if it exists
  -- (pi-style ~/.config/yap/AGENTS.md), otherwise this fallback.
  system = "You are a helpful coding assistant. Answer concisely.",
  agents_file = paths.config_home() .. "/yap/AGENTS.md",
  -- Templates are text files inserted into the context by :YapInsert
  -- (a compaction prompt, a snippet, ...); skills are the same but
  -- system-prompt material, merged into the `# @system` message.
  templates_dir = paths.config_home() .. "/yap/templates",
  skills_dir = paths.config_home() .. "/yap/skills",
  agents_dir = paths.dirs.agents_dir, -- agent-definition files (subagents)
  -- Session data root. Defaults mirror harness.path (the XDG config home,
  -- resolved against the real home directory, never the project cwd);
  -- override in setup() to relocate it. The audit log and notes live beside
  -- each session.
  sessions_dir = paths.dirs.sessions_dir,
  -- vim.notify for a completed turn when its buffer is not visible
  -- (delegated child results go to the running parent instead).
  notify_done = true,
  -- Keep treesitter's markdown syntax highlighting on yap buffers. It is
  -- on by default: the highlighter is incremental and measured to be
  -- negligible (~0.001ms/scroll) — the per-redraw cost attributed to
  -- "treesitter" in profiling was actually touchup re-rendering plus live
  -- buffer churn, not the highlighter. Set false to drop syntax colors.
  syntax_highlight = true,
  -- Terminal glyph availability cannot be detected reliably; set false to use
  -- plain Unicode status glyphs, the original spinner and block gauge.
  nerd_font = true,
  -- UI glyphs for the winbar and session picker (see doc/yap.txt
  -- |yap-winbar|). Defaults are Nerd Font v3 glyphs; the plain-unicode
  -- fallback preset for unpatched fonts is under |yap-configuration|.
  -- Set any to "" to drop its glyph.
  icons = {
    since = "󰅐", -- nf-md-clock_outline (since-open token/cost chip)
    total = "󰆼", -- nf-md-database   (all-time token/cost chip)
    running = "", -- nf-cod-play (rollup: other sessions streaming)
    stopped = "󰓛", -- nf-md-stop (a manually stopped turn)
    error = "󰚌", -- nf-md-skull (winbar error state)
    waiting = "󰫁", -- waiting (rollup: other sessions awaiting you)
    idle = "󰝦", -- nf-md-circle_outline (picker idle state)
    done = "󰄬", -- nf-md-check (picker: finished subagent)
    steer = "󰇐", -- nf-md-directions (winbar steer state)
    approval = "󰻌", -- nf-md-shield_alert (winbar gutter + rollup, notification, audit)
    cap_l = "", -- nf-ple-lower_right_triangle (island left cap)
    cap_r = "", -- nf-ple-lower_left_triangle  (island right cap)
  },
  -- Named model tiers, one "provider/model" combo per role. Every feature
  -- that needs a model reads its tier here, so a tier is set once and every
  -- feature that uses it follows:
  --   agent  — the session worker. Empty falls back to provider/model above
  --            (and a persisted :YapChangeDefaultModel still wins over both).
  --   editor — the one-shot, no-tools model behind :YapEval.
  --   title  — session titling: both the instant on-send label and the
  --            final whole-session summary. Empty disables titling.
  model_groups = {
    agent = "",
    editor = "deepseek/deepseek-v4-pro",
    title = "",
  },
  -- Every keymap is a config key (see doc/yap.txt §3); set one to ""
  -- to disable it. Buffer-local maps are applied when a session opens;
  -- `sessions` and `waiting` are global (installed by setup()).
  keymaps = {
    send = "<C-s>",
    stop = "<C-c>",
    change_model = "<leader>m",
    change_default_model = "<leader>M",
    live = "<leader>l",
    scratch = "<leader>s",
    insert = "<C-t>",
    insert_here = "<leader>T",
    insert_file = "<C-f>",
    sessions = "<leader>r",
    waiting = "<leader>w",
    history = "<leader>y",
    guard = "<leader>g",
    help = "g?",

    next_message = "]m",
    prev_message = "[m",
    next_user = "]u",
    prev_user = "[u",
    next_assistant = "]a",
    prev_assistant = "[a",
    next_tool = "]t",
    prev_tool = "[t",
    next_think = "]c",
    prev_think = "[c",
    next_error = "]e",
    prev_error = "[e",

    view_1 = "<leader>1",
    view_2 = "<leader>2",
    view_3 = "<leader>3",
    toggle_fold = "<Tab>",

    inner_message = "im",
    around_message = "am",
    inner_region = "it",
    around_region = "at",
  },
}

-- Keep the last successful discovery on disk. A refresh starts in the
-- background during setup; the picker uses the cached list immediately.
local models_cache = nil
local models_waiters = {}
local models_refreshing = false

local function models_cache_path()
  return vim.fn.stdpath("cache") .. "/yap/models"
end

-- The last default provider/model picked via change_default_model(),
-- persisted so new buffers reuse it without a rebuild of the (often
-- Nix-managed) setup() defaults. setup() reads it once;
-- change_default_model() rewrites it.
M.default_combo = nil

local function default_combo_path()
  return vim.fn.stdpath("cache") .. "/yap/default"
end

--- Read the persisted default combo, or nil when none is stored.
function M.read_default_combo()
  local path = default_combo_path()
  if vim.fn.filereadable(path) == 1 then
    local lines = vim.fn.readfile(path)
    if #lines == 1 and M.parse_combo(lines[1]) then
      return lines[1]
    end
  end
  return nil
end

--- Persist the default combo and keep the in-memory copy in step.
function M.write_default_combo(combo)
  M.default_combo = combo
  local path = default_combo_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ combo }, path)
end

--- Refresh the cached provider/model list from `yap models`, then release
--- every waiter waiting on it.
function M.refresh_models()
  if models_refreshing then
    return
  end
  models_refreshing = true
  vim.system({ require("harness").config.bin, "models" }, { text = true }, function(res)
    vim.schedule(function()
      models_refreshing = false
      local combos = {}
      if res.code == 0 then
        for line in (res.stdout or ""):gmatch("[^\n]+") do
          table.insert(combos, line)
        end
      end
      if #combos > 0 then
        models_cache = combos
        local path = models_cache_path()
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile(combos, path)
      end
      for _, waiter in ipairs(models_waiters) do
        waiter(models_cache, res.stderr)
      end
      models_waiters = {}
    end)
  end)
end

--- Load the cached model list from disk, so the picker has an immediate
--- list before the async refresh finishes. Returns the cached list (or nil).
function M.load_models_cache()
  local path = models_cache_path()
  if vim.fn.filereadable(path) == 1 then
    local cached = vim.fn.readfile(path)
    if #cached > 0 then
      models_cache = cached
    end
  end
  return models_cache
end

--- Open the provider/model picker and call `cb` with the chosen
--- "provider/model" combo (nothing on dismiss). Reuses setup()'s `models`
--- list when configured, otherwise `yap models` (cached, refreshed async).
function M.pick(cb)
  local function pick(items)
    vim.ui.select(items, { prompt = "yap model" }, function(choice)
      if choice then
        cb(choice)
      end
    end)
  end
  local configured = require("harness").config.models
  if configured and #configured > 0 then
    pick(configured)
    return
  end
  if models_cache then
    pick(models_cache)
    return
  end
  table.insert(models_waiters, function(combos, stderr)
    if not combos then
      local err = (stderr or ""):gsub("%s+$", "")
      vim.notify(
        "yap: model picker unavailable (no models returned)" .. (err ~= "" and (": " .. err) or ""),
        vim.log.levels.WARN
      )
    else
      pick(combos)
    end
  end)
  M.refresh_models()
end

--- The parsed provider/model for a named model group (agent/editor/title),
--- or nil when the group is unset or empty. Resolves `require("harness")`
--- lazily, like current_combo, for the same require-cycle reason.
function M.group(name)
  local groups = require("harness").config.model_groups or {}
  local combo = groups[name]
  if type(combo) == "string" and combo ~= "" then
    local provider, model = M.parse_combo(combo)
    if provider then
      return provider, model
    end
  end
end

--- The combo a brand-new session starts on: the persisted default
--- (:YapChangeDefaultModel), else the `agent` model group, else setup()'s
--- provider/model.
function M.session_combo()
  if M.default_combo then
    local provider, model = M.parse_combo(M.default_combo)
    if provider then
      return provider, model
    end
  end
  local provider, model = M.group("agent")
  if provider then
    return provider, model
  end
  return require("harness").config.provider, require("harness").config.model
end

--- The combo yap will send with: per-buffer vars (set by :Yap /
--- :YapChangeModel), falling back to the session default above.
function M.current_combo(buf)
  local provider, model = vim.b[buf].yap_provider, vim.b[buf].yap_model
  if provider then
    return provider, model
  end
  return M.session_combo()
end

--- Split a "provider/model" combo into provider, model — or nil, nil when the
--- string is not well-formed. The one place the combo grammar lives; used by
--- change_model, change_default_model, the persisted default and the subagent
--- model override. The provider is the first segment; the model may itself
--- contain `/` and `~`, because `yap models` prints provider + "/" + model and
--- ids like `openrouter/anthropic/claude-sonnet-5` or
--- `openrouter/~deepseek/deepseek-flash-latest` are published combos.
function M.parse_combo(combo)
  return combo:match("^([%w_.:%-]+)/([%w_.:~/-]+)$")
end

-- Cache of the compiled-in tool names, used to render the per-session
-- `tools` allowlist in the frontmatter. `yap tools` prints the registry
-- (sorted, one per line); nil when the binary cannot be reached, which
-- leaves a session unrestricted (no `tools:` line).
local tool_names = nil

--- Names of every tool compiled into the binary, cached from `yap tools`.
--- Returns nil when the list is unavailable (then no `tools:` line is
--- written and the backend runs with its full, unrestricted set).
function M.tool_names()
  if tool_names ~= nil then
    return tool_names
  end
  -- With a list argument, systemlist raises E475 when the binary is not
  -- executable (unlike the string form, which reports shell_error). pcall
  -- keeps the documented contract: nil when the binary is unreachable.
  local ok, res = pcall(vim.fn.systemlist, { require("harness").config.bin, "tools" })
  if ok and vim.v.shell_error == 0 and res and #res > 0 then
    tool_names = res
  end
  return tool_names
end

return M
