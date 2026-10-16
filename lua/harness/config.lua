-- yap configuration: the defaults table, provider/model discovery and the
-- persisted default combo. Everything else reads the live table through
-- `require("harness").config` (which init.lua points at M.defaults), so a
-- setup() call extends this table in place and every reader sees it.

local M = {}

local paths = require("harness.path")

M.defaults = {
  bin = "yap", -- path to the yap binary
  provider = "moonshot",
  model = "kimi-k3",
  -- Per-session sampling knob, seeded into a new session's frontmatter so
  -- it is visible and hand-editable from the first line. Delete the line in
  -- a session (or set the default to nil) to fall back to the provider's
  -- own default.
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
  -- Smallest model that labels the session from the latest user message
  -- as soon as it is sent, so the winbar and session picker have a title
  -- before the agent answers.
  description_model = "openai/gpt-5-nano",
  -- Bigger model that writes the final title once the turn completes
  -- (back on the `# @user` message): a whole-session summary that tells the
  -- story so the session is easy to find in the picker later.
  description_answer_model = "openai/gpt-5-mini",
  -- One-shot, no-tools model behind :YapEval — the filter that replaces a
  -- selection (or generates at the cursor) with the model's output. Empty
  -- inherits the buffer's current combo (a session's model, or the setup()
  -- default for a plain buffer); set a dedicated cheap combo like the
  -- description models to override it.
  eval_model = "",
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

--- The combo yap will send with: per-buffer vars (set by :Yap),
--- falling back to the global config. Resolves `require("harness")` lazily
--- so this module can be loaded during the harness's own require cycle.
function M.current_combo(buf)
  local config = require("harness").config
  return vim.b[buf].yap_provider or config.provider, vim.b[buf].yap_model or config.model
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
