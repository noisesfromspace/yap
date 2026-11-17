-- yap configuration: the defaults table and provider/model discovery.
-- Everything else reads the live table through
-- `require("harness").config` (which init.lua points at M.defaults), so a
-- setup() call extends this table in place and every reader sees it.

local M = {}

local paths = require("harness.path")

M.defaults = {
  bin = "yap", -- path to the yap binary
  -- System prompt for new buffers: read from agents_file if it exists
  -- (pi-style ~/.config/yap/AGENTS.md), otherwise this fallback.
  system = "You are a helpful coding assistant. Answer concisely.",
  agents_file = paths.config_home() .. "/yap/AGENTS.md",
  -- Templates are text files inserted into the context by insert()
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
  -- Neovim's built-in completion is enabled on Yap buffers by default.
  builtin_completion = true,
  -- Terminal glyph availability cannot be detected reliably; set false to use
  -- plain Unicode status glyphs, the original spinner and block gauge.
  nerd_font = true,
  -- Pre-send cost guard: ask before a turn that would cost more than this, on
  -- a worst-case estimate of context x two model steps x the model's uncached
  -- input rate (caching only ever makes it cheaper). The picker shows the same
  -- rate per 1M tokens, so an accidental switch to a top-tier model is visible
  -- before it costs anything. `enabled = false` turns the guard off; a single
  -- "send anyway" covers the rest of the session for that model.
  price_guard = {
    enabled = true,
    max_usd = 2.0,
  },
  -- UI glyphs for the winbar and session picker (see doc/yap.txt
  -- |yap-winbar|). Defaults are Nerd Font v3 glyphs; the plain-unicode
  -- fallback preset for unpatched fonts is under |yap-configuration|.
  -- Set any to "" to drop its glyph.
  icons = {
    since = "󰅐", -- nf-md-clock_outline (since-open token/cost chip)
    total = "󰆼", -- nf-md-database   (all-time token/cost chip)
    cache = "󰃨", -- nf-md-cached     (winbar cache read-hit chip)
    running = "", -- nf-cod-play (rollup: other sessions streaming)
    stopped = "󰓛", -- nf-md-stop (a manually stopped turn)
    error = "󰚌", -- nf-md-skull (winbar error state)
    waiting = "󰫁", -- waiting (rollup: other sessions awaiting you)
    idle = "󰝦", -- nf-md-circle_outline (picker idle state)
    done = "󰄬", -- nf-md-check (picker: finished subagent)
    steer = "󰇐", -- nf-md-directions (winbar steer state)
    queue = "󱊖", -- nf-md-tray_full (winbar queued-message state)
    clear = "󰃢", -- nf-md-broom (winbar queued-clear state)
    model_switch = "󰿡", -- nf-md-swap_horizontal_circle (winbar pending model switch)
    approval = "󰻌", -- nf-md-shield_alert (winbar gutter + rollup, notification, audit)
    fork = "󰓁", -- nf-md-source_fork (picker: a fork in the session tree)
    cap_l = "", -- nf-ple-lower_right_triangle (island left cap)
    cap_r = "", -- nf-ple-lower_left_triangle  (island right cap)
  },
  -- Model tiers: regular sessions use agent; cheap one-shot work uses flash.
  -- flash also generates short session descriptions; "" disables those
  -- descriptions and makes :YapEval! use agent.
  model_groups = {
    agent = "openai/gpt-6.1-sol",
    flash = "deepseek/deepseek-flash",
  },
  -- Every keymap is a config key (see doc/yap.txt §3); set one to ""
  -- to disable it. Buffer-local maps are applied when a session opens;
  -- `sessions` and `guard` are global (installed by setup()).
  keymaps = {
    send = "<C-s>",
    stop = "<C-c>",
    change_model = "<leader>m",
    live = "<leader>l",
    scratch = "<leader>j",
    insert = "<C-CR>",
    sessions = "+",
    sessions_all = "g+",
    symbols = "<leader>s",
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
-- combo name -> catalog entry (`input`, `output`, `cache_read`, `context`),
-- from the same discovery call. Empty when the cache predates `yap models
-- --json`, in which case the picker shows names only and the cost guard stands
-- down: an unknown price must never be guessed at.
local models_prices = nil
local models_waiters = {}
local models_refreshing = false

--- Path of the cached provider/model list, written by refresh_models from
--- `yap models`. Exported so the yap LSP client can hand it to the server
--- (the Go side cannot derive Neovim's cache directory).
function M.models_cache_path()
  return vim.fn.stdpath("cache") .. "/yap/models"
end

--- Path of the sibling price cache, the same discovery call in JSON form. Kept
--- separate so the plain list stays the LSP's stable input.
function M.models_price_path()
  return vim.fn.stdpath("cache") .. "/yap/models.json"
end

--- The catalog entry for a `provider/model` combo, or nil when unknown.
--- Never invents a price: a missing entry means the picker omits the rate and
--- the cost guard does not fire.
function M.model_price(combo)
  if not models_prices then
    M.load_models_cache()
  end
  return models_prices and models_prices[combo] or nil
end

--- Parse one `yap models --json` payload into a name list and a price map.
local function parse_models_json(payload)
  local ok, decoded = pcall(vim.json.decode, payload)
  if not ok or type(decoded) ~= "table" then
    return nil, nil
  end
  local names, prices = {}, {}
  for _, entry in ipairs(decoded) do
    if type(entry) == "table" and type(entry.name) == "string" and entry.name ~= "" then
      names[#names + 1] = entry.name
      prices[entry.name] = entry
    end
  end
  return names, prices
end

--- Refresh the cached provider/model list from `yap models`, then release
--- every waiter waiting on it.
function M.refresh_models()
  if models_refreshing then
    return
  end
  local bin = require("harness").config.bin
  if not bin or bin == "" or vim.fn.executable(bin) ~= 1 then
    for _, waiter in ipairs(models_waiters) do
      waiter(models_cache, "binary is not executable: " .. tostring(bin))
    end
    models_waiters = {}
    return
  end
  models_refreshing = true
  vim.system({ bin, "models", "--json" }, { text = true }, function(res)
    vim.schedule(function()
      models_refreshing = false
      local combos, prices
      if res.code == 0 then
        combos, prices = parse_models_json(res.stdout or "")
      end
      if combos and #combos > 0 then
        models_cache = combos
        models_prices = prices
        local dir = vim.fn.fnamemodify(M.models_cache_path(), ":h")
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile(combos, M.models_cache_path())
        vim.fn.writefile(vim.split((res.stdout or ""):gsub("%s+$", ""), "\n"), M.models_price_path())
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
  local path = M.models_cache_path()
  if vim.fn.filereadable(path) == 1 then
    local cached = vim.fn.readfile(path)
    if #cached > 0 then
      models_cache = cached
    end
  end
  -- Prices come from the sibling JSON cache, so a picker opened before the
  -- async refresh finishes still shows rates.
  if not models_prices then
    local jpath = M.models_price_path()
    if vim.fn.filereadable(jpath) == 1 then
      local names, prices = parse_models_json(table.concat(vim.fn.readfile(jpath), "\n"))
      if names and #names > 0 then
        models_prices = prices
        models_cache = models_cache or names
      end
    end
  end
  return models_cache
end

--- Format a rate for display: `$10`, `$0.28`, `$2.50`. Trailing zeros stay
--- off so picker rows stay narrow.
local function money(v)
  if not v or v <= 0 then
    return nil
  end
  return "$" .. (string.format("%g", v))
end

--- Preview lines for one combo: the rate that makes an accidental switch to a
--- top-tier model visible before it costs anything. Empty when the catalog has
--- no entry, so the picker shows its default preview instead of inventing a
--- price.
function M.model_preview(combo)
  local info = M.model_price(combo)
  if not info then
    return nil
  end
  local input, output = money(info.input), money(info.output)
  local lines = { combo, "" }
  if input and output then
    lines[#lines + 1] = string.format("  %s in · %s out  per 1M tokens", input, output)
  else
    lines[#lines + 1] = "  rate unknown to the catalog"
  end
  local cached = money(info.cache_read)
  if cached then
    lines[#lines + 1] = string.format("  %s per 1M cached input", cached)
  end
  if info.context and info.context > 0 then
    lines[#lines + 1] = string.format("  %s context window", require("harness.util").fmt_tokens(info.context))
  end
  return lines
end

--- Open the provider/model picker and call `cb` with the chosen
--- "provider/model" combo (nothing on dismiss). Uses the backend's cached
--- discovery list, refreshed asynchronously during setup.
---
--- The row stays just the combo name; the rate and context window live in the
--- preview (`preview_item`, a mini.pick extension to `vim.ui.select`). A
--- plain `vim.ui.select` ignores the preview and the picker still works.
function M.pick(cb)
  local function pick(items)
    vim.ui.select(items, {
      prompt = "yap model",
      format_item = function(item)
        return item
      end,
      preview_item = function(item)
        return M.model_preview(item) or { item }
      end,
    }, function(choice)
      if choice then
        cb(choice)
      end
    end)
  end
  if models_cache then
    pick(models_cache)
    -- A cached list can be stale: a provider was briefly down, or its API
    -- keys were not yet sourced, when setup() refreshed. Re-run discovery in
    -- the background so the next open self-heals without a Neovim restart.
    M.refresh_models()
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

--- The combo a brand-new session starts on.
function M.session_combo()
  return M.group("agent")
end

--- The combo yap will send with: per-buffer vars (set by new() /
--- change_model()), falling back to the session default above.
function M.current_combo(buf)
  local provider, model = vim.b[buf].yap_provider, vim.b[buf].yap_model
  if provider then
    return provider, model
  end
  return M.session_combo()
end

--- Split a "provider/model" combo into provider, model — or nil, nil when the
--- string is not well-formed. The one place the combo grammar lives; used by
--- model groups, change_model and subagent overrides. The provider is the
--- first segment; the model may itself
--- contain `/` and `~`, because `yap models` prints provider + "/" + model and
--- ids like `openrouter/anthropic/claude-sonnet-5` or
--- `openrouter/~deepseek/deepseek-flash-latest` are published combos.
function M.parse_combo(combo)
  return combo:match("^([%w_.:%-]+)/([%w_.:~/-]+)$")
end

return M
