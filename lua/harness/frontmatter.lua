-- yap session frontmatter: the durable per-session state.
--
-- Scope is deliberately narrow — only durable per-session state lives here:
--
--   ---
--   description: Fix session picker labels and summaries
--   model: kimi-k3
--   provider: moonshot
--   created_cwd: /opt/code/yap
--   agent: reviewer
--   tools: read,search,glob
--   turns: 14
--   created_at: 2025-09-29T19:22:33Z
--   updated_at: 2025-09-29T19:24:01Z
--   models:
--     - moonshot/kimi-k3
--     - deepseek/deepseek-v4-pro
--   forked_from: /home/martijn/.yap/sessions/.../source.md
--   subagent_parent: /home/martijn/.yap/sessions/.../parent.md
--   subagents:
--     - /home/martijn/.yap/sessions/.../session-a1b2c3.md
--   forks:
--     - /home/martijn/.yap/sessions/.../branch.md
--   ---
--
-- `description` is the one-line summary the picker shows; `model` and
-- `provider` are the combo to resume with; `created_cwd` is the exact working
-- directory the session was created in (the directory slug is lossy, so
-- this is the only exact record of where a session ran); `agent`/`tools`
-- mark a subagent session (its agent-definition name and the tools it may call);
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

local function is_list_key(k)
  return k == "models" or k == "subagents" or k == "forks"
end

--- Parse frontmatter from a Lua list of lines. Returns
--- { provider, model, created_cwd, created_at, updated_at, turns, description, agent,
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
      elseif k == "created_cwd" or k == "cwd" then -- "cwd" is the pre-rename key
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
      elseif k == "description" then
        fm.description = v
      elseif k == "agent" then
        fm.agent = v
      elseif k == "tools" then
        fm.tools = vim.split(v, ",", { plain = true })
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
        else
          fm.forks[#fm.forks + 1] = item
        end
      end
    end
  end
  return nil -- unterminated
end

--- Render the frontmatter for a combo + ordered history. The
--- returned table has no trailing blank line (see module comment).
function M.render(
  provider,
  model,
  models,
  created_at,
  description,
  agent,
  tools,
  subagents,
  updated_at,
  turns,
  created_cwd,
  forked_from,
  forks,
  subagent_parent
)
  local lines = { "---" }
  if description and description ~= "" then
    lines[#lines + 1] = "description: " .. description:gsub("[\r\n]+", " "):gsub(":%s*$", "")
  end
  lines[#lines + 1] = "model: " .. model
  lines[#lines + 1] = "provider: " .. provider
  if created_cwd and created_cwd ~= "" then
    lines[#lines + 1] = "created_cwd: " .. created_cwd
  end
  if agent then
    lines[#lines + 1] = "agent: " .. agent
  end
  if tools then
    lines[#lines + 1] = "tools: " .. table.concat(tools, ",")
  end
  if turns ~= nil then
    lines[#lines + 1] = "turns: " .. turns
  end
  if created_at then
    lines[#lines + 1] = "created_at: " .. created_at
  end
  if updated_at then
    lines[#lines + 1] = "updated_at: " .. updated_at
  end
  if models and #models > 0 then
    lines[#lines + 1] = "models:"
    for _, c in ipairs(models) do
      lines[#lines + 1] = "  - " .. c
    end
  end
  if forked_from then
    lines[#lines + 1] = "forked_from: " .. forked_from
  end
  if subagent_parent then
    lines[#lines + 1] = "subagent_parent: " .. subagent_parent
  end
  if subagents and #subagents > 0 then
    lines[#lines + 1] = "subagents:"
    for _, p in ipairs(subagents) do
      lines[#lines + 1] = "  - " .. p
    end
  end
  if forks and #forks > 0 then
    lines[#lines + 1] = "forks:"
    for _, p in ipairs(forks) do
      lines[#lines + 1] = "  - " .. p
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
  local block = M.render(
    provider,
    model,
    models,
    created_at,
    fm and fm.description,
    fm and fm.agent or vim.b[buf].yap_agent,
    fm and fm.tools or vim.b[buf].yap_tools,
    fm and fm.subagents,
    fm and fm.updated_at,
    fm and fm.turns,
    created_cwd,
    fm and fm.forked_from,
    fm and fm.forks,
    fm and fm.subagent_parent
  )
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
  local block = M.render(
    fm.provider,
    fm.model,
    fm.models,
    fm.created_at,
    fm.description,
    fm.agent,
    fm.tools,
    subagents,
    fm.updated_at,
    fm.turns,
    fm.created_cwd,
    fm.forked_from,
    fm.forks,
    fm.subagent_parent
  )
  vim.api.nvim_buf_set_lines(parent, 0, e, false, block)
end

return M
