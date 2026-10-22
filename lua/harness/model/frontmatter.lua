-- yap session frontmatter: the durable per-session state.
--
-- Scope is deliberately narrow — only durable per-session state lives here:
--
--   ---
--   title: Fix session picker labels
--   description: Fix session picker labels and summaries
--   model: kimi-k3
--   provider: moonshot
--   available_reasoning:
--     - low
--     - medium
--     - high
--   reasoning_level: high
--   created_cwd: ~/code/project
--   agent: reviewer
--   tools:
--     - read
--     - search
--     - glob
--   turns: 14
--   created_at: 2025-09-29T19:22:33Z
--   updated_at: 2025-09-29T19:24:01Z
--   models:
--     - moonshot/kimi-k3
--     - deepseek/deepseek-v4-pro
--   forked_from: ~/.config/yap/sessions/.../source.md
--   subagent_parent: ~/.config/yap/sessions/.../parent.md
--   subagents:
--     - ~/.config/yap/sessions/.../session-a1b2c3.md
--   forks:
--     - ~/.config/yap/sessions/.../branch.md
--   ---
--
-- `title` is always present (empty by default) and wins over `description`
-- when you type a value into it; `description` is the generated one-line
-- summary the picker shows while the title is empty; `model` and
-- `provider` are the combo to resume with; `available_reasoning` lists the
-- reasoning levels on offer and `reasoning_level` (low|medium|high) is the
-- live, hand-editable choice — read on every send, empty means the
-- provider's own default;
-- `created_cwd` is the exact working
-- directory the session was created in (the directory slug is lossy, so
-- this is the only exact record of where a session ran); `agent` marks a
-- subagent session (its agent-definition name); `tools` is the per-session
-- tool allowlist — a normal session lists every compiled-in tool so lines can
-- be removed to retract access on the next send, while a subagent lists only
-- its definition's tools;
-- `turns` counts the completed replies (`# @assistant` messages) — a
-- session-depth summary for the picker, stamped on save with `updated_at`;
-- `created_at` records when the session was created; `updated_at` records
-- its last write (stamped on every save); `models` is the ordered history
-- of every combo actually used (most-recent-last); `forked_from` and
-- `forks` link copied sessions in both directions; `subagent_parent` points
-- back to the owner; `subagents` is the ordered list of subagent session
-- paths this session ran (most-recent-last).
-- Token/cost
-- totals are NOT persisted here — the winbar accumulates them per-buffer,
-- and the durable session total is derived from the audit log, not the file.
-- yap owns the frontmatter, so parsing is a few pattern matches,
-- not a YAML library; Neovim has no YAML parser and does not need one.
--
-- render() returns ONLY the `--- ... ---` frontmatter (no trailing blank line);
-- callers own the blank separator that follows it.

local M = {}

local config = require("harness.config")

-- The reasoning levels a session can select. Rendered into the frontmatter as
-- `available_reasoning` so the options are visible next to the active choice;
-- the active value itself is what gets sent.
local AVAILABLE_REASONING = { "low", "medium", "high" }

local function is_list_key(k)
  return k == "models" or k == "subagents" or k == "forks"
end

--- Parse frontmatter from a Lua list of lines. Returns
--- { provider, model, created_cwd, created_at, updated_at, turns, title, description, agent,
---   tools = {name,...}, models = {combo,...}, subagents = {path,...},
---   forks = {path,...}, forked_from = path?, subagent_parent = path? }
--- or nil when there is none (or it is unterminated). Tolerant on read:
--- unknown keys and comments are ignored, so a hand-edited frontmatter does not
--- break resuming.
function M.parse(lines)
  if not lines or not lines[1] or not lines[1]:match("^%-%-%-%s*$") then
    return nil
  end
  local fm = { models = {}, subagents = {}, forks = {} }
  local list_key = nil
  for i = 2, #lines do
    local line = lines[i]
    if line:match("^%-%-%-%s*$") then
      return fm
    end
    local k, v = line:match("^(%S+):%s*(.-)%s*$")
    if k then
      list_key = nil
      if k == "provider" then
        fm.provider = v
      elseif k == "model" then
        fm.model = v
      elseif k == "created_cwd" then
        fm.created_cwd = v
      elseif k == "created_at" then
        fm.created_at = v
      elseif k == "updated_at" then
        fm.updated_at = v
      elseif k == "subagent_parent" then
        fm.subagent_parent = v
      elseif k == "forked_from" then
        fm.forked_from = v
      elseif k == "turns" then
        fm.turns = tonumber(v)
      elseif k == "title" then
        fm.title = v
      elseif k == "description" then
        fm.description = v
      elseif k == "agent" then
        fm.agent = v
      elseif k == "reasoning_level" then
        fm.reasoning_level = v
      elseif k == "tools" then
        list_key = "tools"
      elseif is_list_key(k) then
        list_key = k
      end
    elseif list_key then
      local item = line:match("^%s*%-%s*(.-)%s*$")
      if item and item ~= "" then
        if list_key == "models" then
          fm.models[#fm.models + 1] = item
        elseif list_key == "subagents" then
          fm.subagents[#fm.subagents + 1] = item
        elseif list_key == "forks" then
          fm.forks[#fm.forks + 1] = item
        elseif list_key == "tools" then
          fm.tools = fm.tools or {}
          fm.tools[#fm.tools + 1] = item
        end
      end
    end
  end
  return nil -- unterminated
end

--- Render the frontmatter for a combo + ordered history. The
--- returned table has no trailing blank line (see module comment).
function M.render(fm)
  local lines = { "---" }
  -- `title` is always written (empty by default) so a hand-edited value sits
  -- in the buffer ready to fill in; an empty title leaves the generated
  -- description in charge.
  local t = fm.title and fm.title:gsub("[\r\n]+", " "):gsub(":%s*$", "") or ""
  lines[#lines + 1] = (t == "" and "title:" or ("title: " .. t))
  if fm.description and fm.description ~= "" then
    lines[#lines + 1] = "description: " .. fm.description:gsub("[\r\n]+", " "):gsub(":%s*$", "")
  end
  lines[#lines + 1] = "model: " .. fm.model
  lines[#lines + 1] = "provider: " .. fm.provider
  lines[#lines + 1] = "available_reasoning:"
  for _, level in ipairs(AVAILABLE_REASONING) do
    lines[#lines + 1] = "  - " .. level
  end
  if fm.reasoning_level and fm.reasoning_level ~= "" then
    lines[#lines + 1] = "reasoning_level: " .. fm.reasoning_level
  end
  if fm.created_cwd and fm.created_cwd ~= "" then
    lines[#lines + 1] = "created_cwd: " .. fm.created_cwd
  end
  if fm.agent then
    lines[#lines + 1] = "agent: " .. fm.agent
  end
  if fm.turns ~= nil then
    lines[#lines + 1] = "turns: " .. fm.turns
  end
  if fm.created_at then
    lines[#lines + 1] = "created_at: " .. fm.created_at
  end
  if fm.updated_at then
    lines[#lines + 1] = "updated_at: " .. fm.updated_at
  end
  if fm.models and #fm.models > 0 then
    lines[#lines + 1] = "models:"
    for _, c in ipairs(fm.models) do
      lines[#lines + 1] = "  - " .. c
    end
  end
  if fm.forked_from then
    lines[#lines + 1] = "forked_from: " .. fm.forked_from
  end
  if fm.subagent_parent then
    lines[#lines + 1] = "subagent_parent: " .. fm.subagent_parent
  end
  if fm.subagents and #fm.subagents > 0 then
    lines[#lines + 1] = "subagents:"
    for _, p in ipairs(fm.subagents) do
      lines[#lines + 1] = "  - " .. p
    end
  end
  if fm.forks and #fm.forks > 0 then
    lines[#lines + 1] = "forks:"
    for _, p in ipairs(fm.forks) do
      lines[#lines + 1] = "  - " .. p
    end
  end
  if fm.tools and #fm.tools > 0 then
    lines[#lines + 1] = "tools:"
    for _, t in ipairs(fm.tools) do
      lines[#lines + 1] = "  - " .. t
    end
  end
  lines[#lines + 1] = "---"
  return lines
end

--- End line (0-based, exclusive) of the frontmatter, or nil when
--- the buffer has none. Only the model state lives here; token/cost totals
--- stay in the winbar.
function M.end_line(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 200, false)
  if not lines[1] or not lines[1]:match("^%-%-%-%s*$") then
    return nil
  end
  for i = 2, #lines do
    if lines[i]:match("^%-%-%-%s*$") then
      return i
    end
  end
  return nil
end

--- Update fields in an existing buffer frontmatter without rebuilding the
--- other fields at every call site. Returns false when no block is present.
--- Callers decide whether and when to save the buffer.
function M.update(buf, changes)
  local e = M.end_line(buf)
  if not e then
    return false
  end
  local fm = M.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
  if not fm then
    return false
  end
  vim.api.nvim_buf_set_lines(buf, 0, e, false, M.render(vim.tbl_extend("force", fm, changes)))
  return true
end

--- Rewrite the buffer's frontmatter to match the current combo, growing
--- the `models` history. Called only from new()/change_model() — never
--- during a send (R-blank-lines: sends only append).
function M.sync(buf)
  local provider, model = config.current_combo(buf)
  local combo = provider .. "/" .. model
  local e = M.end_line(buf)
  local fm = e and M.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false)) or nil
  local models = fm and fm.models or {}
  if #models == 0 and fm and fm.provider and fm.model then
    table.insert(models, fm.provider .. "/" .. fm.model)
  end
  if models[#models] ~= combo then
    table.insert(models, combo)
  end
  local created_at = (fm and fm.created_at) or os.date("!%Y-%m-%dT%H:%M:%SZ")
  -- The exact cwd is recorded once, when the session is created; later
  -- rewrites preserve it (the session dir slug alone is lossy).
  local created_cwd = (fm and fm.created_cwd) or vim.b[buf].yap_project_cwd
  -- Seed the sampling knob from config defaults only when creating a
  -- session (no frontmatter yet); an existing session keeps whatever the
  -- user left in the buffer — deleting the line restores the provider
  -- default.
  local defaults = require("harness").config
  local reasoning_level = (not fm and defaults.reasoning_level) or (fm and fm.reasoning_level)
  local block = M.render(vim.tbl_extend("force", fm or {}, {
    provider = provider,
    model = model,
    models = models,
    created_at = created_at,
    agent = (fm and fm.agent) or vim.b[buf].yap_agent,
    tools = (fm and fm.tools) or vim.b[buf].yap_tools or config.tool_names(),
    created_cwd = created_cwd,
    reasoning_level = reasoning_level,
  }))
  if e then
    vim.api.nvim_buf_set_lines(buf, 0, e, false, block)
  else
    table.insert(block, "")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, block)
  end
end

--- Append a subagent session path to the parent's frontmatter `subagents`
--- list. It records ownership for tool follow-ups; saved children also appear
--- in the session history picker.
function M.record_subagent(parent, child_path)
  local e = M.end_line(parent)
  if not e then
    return
  end
  local fm = M.parse(vim.api.nvim_buf_get_lines(parent, 0, e, false))
  if not fm then
    return
  end
  local subagents = fm.subagents or {}
  for _, p in ipairs(subagents) do
    if p == child_path then
      return
    end
  end
  subagents[#subagents + 1] = child_path
  fm.subagents = subagents
  vim.api.nvim_buf_set_lines(parent, 0, e, false, M.render(fm))
end

return M
