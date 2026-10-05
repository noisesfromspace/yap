-- yap session frontmatter: the durable per-session state.
--
-- Scope is deliberately narrow — only durable per-session state lives here:
--
--   ---
--   provider: moonshot
--   model: kimi-k3
--   role: reviewer
--   tools: read,search,glob
--   created_at: 2025-09-29T19:22:33Z
--   updated_at: 2025-09-29T19:24:01Z
--   turns: 14
--   description: Fix session picker labels and summaries
--   models:
--     - moonshot/kimi-k3
--     - deepseek/deepseek-v4-pro
--   subagents:
--     - /home/martijn/.yap/sessions/.../session-a1b2c3.md
--   ---
--
-- `provider`/`model` is the combo to resume with; `role`/`tools` mark a
-- subagent session (its role name and the tools it may call); `created_at`
-- records when the session was created; `updated_at` records its last
-- write (stamped on every save); `turns` counts the completed replies
-- (`# @assistant` blocks) — a session-depth summary for the picker, stamped
-- on save with `updated_at`; `models` is the ordered history of every combo
-- actually used (most-recent-last); `subagents` is the ordered list of
-- subagent session paths this session ran (most-recent-last).
-- Token/cost
-- totals are NOT persisted here — the winbar accumulates them per-buffer,
-- and the durable session total is derived from the audit log, not the file.
-- yap owns the block, so parsing is a few pattern matches,
-- not a YAML library; Neovim has no YAML parser and does not need one.
--
-- render() returns ONLY the `--- ... ---` block (no trailing blank line);
-- callers own the blank separator that follows it.

local M = {}

local function is_list_key(k)
  return k == "models" or k == "subagents"
end

--- Parse a frontmatter block from a Lua list of lines. Returns
--- { provider, model, created_at, updated_at, turns, description, role,
---   tools = {name,...}, models = {combo,...}, subagents = {path,...} }
--- or nil when there is none (or it is unterminated). Tolerant on read:
--- unknown keys and comments are ignored, so a hand-edited block does not
--- break resuming.
function M.parse(lines)
  if not lines or not lines[1] or not lines[1]:match("^%-%-%-%s*$") then
    return nil
  end
  local fm = { models = {}, subagents = {} }
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
      elseif k == "created_at" then
        fm.created_at = v
      elseif k == "updated_at" then
        fm.updated_at = v
      elseif k == "turns" then
        fm.turns = tonumber(v)
      elseif k == "description" then
        fm.description = v
      elseif k == "role" then
        fm.role = v
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
        else
          fm.subagents[#fm.subagents + 1] = item
        end
      end
    end
  end
  return nil -- unterminated
end

--- Render the frontmatter block for a combo + ordered history. The
--- returned table has no trailing blank line (see module comment).
function M.render(provider, model, models, created_at, description, role, tools, subagents, updated_at, turns)
  local lines = { "---", "provider: " .. provider, "model: " .. model }
  if role then lines[#lines + 1] = "role: " .. role end
  if tools then lines[#lines + 1] = "tools: " .. table.concat(tools, ",") end
  if created_at then
    lines[#lines + 1] = "created_at: " .. created_at
  end
  if updated_at then
    lines[#lines + 1] = "updated_at: " .. updated_at
  end
  if turns ~= nil then
    lines[#lines + 1] = "turns: " .. turns
  end
  if description and description ~= "" then
    lines[#lines + 1] = "description: " .. description:gsub("[\r\n]+", " "):gsub(":%s*$", "")
  end
  if models and #models > 0 then
    lines[#lines + 1] = "models:"
    for _, c in ipairs(models) do
      lines[#lines + 1] = "  - " .. c
    end
  end
  if subagents and #subagents > 0 then
    lines[#lines + 1] = "subagents:"
    for _, p in ipairs(subagents) do
      lines[#lines + 1] = "  - " .. p
    end
  end
  lines[#lines + 1] = "---"
  return lines
end

return M
