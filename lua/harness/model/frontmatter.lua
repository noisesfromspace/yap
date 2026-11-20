-- yap session frontmatter: the durable per-session state.
--
-- Scope is deliberately narrow — only durable per-session state lives here:
--
--   ---
--   description: Fix session picker labels and summaries
--   model: kimi-k3
--   provider: moonshot
--   created_cwd: ~/code/project
--   agent: reviewer
--   tools:
--     - read
--     - search
--     - glob
--   turns: 14
--   created_at: 2025-09-29T19:22:33Z
--   updated_at: 2025-09-29T19:24:01Z
--   previous:
--     moonshot/kimi-k3: 2025-09-29T19:22:33Z
--     deepseek/deepseek-v4-pro: 2025-09-29T19:24:01Z
--   forked_from: ~/.config/yap/sessions/.../source/
--   subagent_parent: ~/.config/yap/sessions/.../parent/
--   ---
--
-- Field semantics and the write rules: R-frontmatter (AGENTS.md) and
-- section 5 of doc/yap.txt. The session title is the transcript's filename;
-- token and cost totals are not here — the winbar accumulates them per buffer
-- and the durable total is derived from the audit log.
--
-- yap owns the frontmatter, so parsing is a few pattern matches, not a YAML
-- library. render() returns ONLY the `--- ... ---` frontmatter (no trailing
-- blank line); callers own the blank separator that follows it.

local M = {}

local config = require("harness.config")

local function is_list_key(k)
  return k == "tools"
end

local function is_map_key(k)
  return k == "previous"
end

--- Parse frontmatter from a Lua list of lines. Returns
--- { provider, model, created_cwd, created_at, updated_at, turns, description, agent,
---   tools = {name,...}, previous = {[combo] = timestamp,...}, forked_from = dir?, subagent_parent = dir? }
--- or nil when there is none (or it is unterminated). Tolerant on read:
--- unknown keys and comments are ignored, so a hand-edited frontmatter does not
--- break resuming.
function M.parse(lines)
  if not lines or not lines[1] or not lines[1]:match("^%-%-%-%s*$") then
    return nil
  end
  local fm = { previous = {} }
  local list_key, map_key = nil, nil
  for i = 2, #lines do
    local line = lines[i]
    if line:match("^%-%-%-%s*$") then
      return fm
    end
    local k, v = line:match("^(%S+):%s*(.-)%s*$")
    if k then
      list_key, map_key = nil, nil
      if k == "provider" then
        fm.provider = v
      elseif k == "model" then
        fm.model = v
      elseif k == "created_cwd" then
        fm.created_cwd = v
      elseif k == "data_dir" then
        fm.data_dir = v
      elseif k == "created_at" then
        fm.created_at = v
      elseif k == "updated_at" then
        fm.updated_at = v
      elseif k == "kind" then
        fm.kind = v
      elseif k == "eval_status" then
        fm.eval_status = v
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
      elseif is_list_key(k) then
        list_key = k
      elseif is_map_key(k) then
        map_key = k
      end
    elseif list_key then
      local item = line:match("^%s*%-%s*(.-)%s*$")
      if item and item ~= "" and list_key == "tools" then
        fm.tools = fm.tools or {}
        fm.tools[#fm.tools + 1] = item
      end
    elseif map_key then
      local mk, mv = line:match("^%s*(%S+):%s*(.-)%s*$")
      if mk and mk ~= "" and map_key == "previous" then
        fm.previous[mk] = mv
      end
    end
  end
  return nil -- unterminated
end

--- Render the frontmatter for a combo + previous-model map. The
--- returned table has no trailing blank line (see module comment).
function M.render(fm)
  local lines = { "---" }
  if fm.description and fm.description ~= "" then
    lines[#lines + 1] = "description: " .. fm.description:gsub("[\r\n]+", " "):gsub(":%s*$", "")
  end
  lines[#lines + 1] = "model: " .. fm.model
  lines[#lines + 1] = "provider: " .. fm.provider
  if fm.created_cwd and fm.created_cwd ~= "" then
    lines[#lines + 1] = "created_cwd: " .. fm.created_cwd
  end
  if fm.data_dir and fm.data_dir ~= "" then
    lines[#lines + 1] = "data_dir: " .. fm.data_dir
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
  if fm.previous and vim.tbl_count(fm.previous) > 0 then
    local prev = {}
    for combo, ts in pairs(fm.previous) do
      prev[#prev + 1] = { combo = combo, ts = ts }
    end
    table.sort(prev, function(a, b) return a.ts < b.ts end)
    lines[#lines + 1] = "previous:"
    for _, entry in ipairs(prev) do
      lines[#lines + 1] = "  " .. entry.combo .. ": " .. entry.ts
    end
  end
  if fm.kind then
    lines[#lines + 1] = "kind: " .. fm.kind
  end
  if fm.eval_status then
    lines[#lines + 1] = "eval_status: " .. fm.eval_status
  end
  if fm.forked_from then
    lines[#lines + 1] = "forked_from: " .. fm.forked_from
  end
  if fm.subagent_parent then
    lines[#lines + 1] = "subagent_parent: " .. fm.subagent_parent
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

--- Rewrite the existing block, lines 1..e, with `block`, touching only the
--- lines that differ. An unchanged `---` line keeps both the window's manual
--- `options` fold over the block and the anchor carrying its open/closed
--- choice: replacing the whole block (as every re-stamp of `updated_at` did)
--- deletes the fold, so a save collapsed the frontmatter under the cursor.
local function write_block(buf, e, block)
  local old = vim.api.nvim_buf_get_lines(buf, 0, e, false)
  local first, last_old, last_new = 1, #old, #block
  while first <= last_old and first <= last_new and old[first] == block[first] do
    first = first + 1
  end
  while last_old >= first and last_new >= first and old[last_old] == block[last_new] do
    last_old, last_new = last_old - 1, last_new - 1
  end
  if first > last_old and first > last_new then
    return -- nothing differs: no edit, so no 'modified' flag and no fold reconcile
  end
  vim.api.nvim_buf_set_lines(buf, first - 1, last_old, false, vim.list_slice(block, first, last_new))
end

--- Replace the frontmatter block ending at line `e` with `fm`, keeping every
--- line that does not change.
function M.write(buf, e, fm)
  write_block(buf, e, M.render(fm))
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
  M.write(buf, e, vim.tbl_extend("force", fm, changes))
  return true
end

--- Rewrite the buffer's frontmatter to match the current combo, stamping
--- the `previous` map with each combo's last-used timestamp. Called only
--- from new()/change_model() — never during a send (R-blank-lines: sends
--- only append).
function M.sync(buf)
  local provider, model = config.current_combo(buf)
  local combo = provider .. "/" .. model
  local e = M.end_line(buf)
  local fm = e and M.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false)) or nil
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local previous = fm and fm.previous or {}
  if vim.tbl_count(previous) == 0 and fm and fm.provider and fm.model then
    previous[fm.provider .. "/" .. fm.model] = fm.created_at or now
  end
  previous[combo] = now
  local created_at = (fm and fm.created_at) or now
  -- The exact cwd is recorded once, when the session is created; later
  -- rewrites preserve it (the session dir slug alone is lossy).
  local created_cwd = (fm and fm.created_cwd) or vim.b[buf].yap_project_cwd
  local merged = vim.tbl_extend("force", fm or {}, {
    provider = provider,
    model = model,
    previous = previous,
    created_at = created_at,
    agent = (fm and fm.agent) or vim.b[buf].yap_agent,
    tools = (fm and fm.tools) or vim.b[buf].yap_tools,
    created_cwd = created_cwd,
    data_dir = (fm and fm.data_dir) or vim.b[buf].yap_data_dir,
  })
  if e then
    M.write(buf, e, merged)
  else
    local block = M.render(merged)
    table.insert(block, "")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, block)
  end
end

return M
