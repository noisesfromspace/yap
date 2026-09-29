-- pitel session frontmatter: the durable per-session state.
--
-- Scope is deliberately narrow — only durable per-session state lives here:
--
--   ---
--   provider: moonshot
--   model: kimi-k3
--   created_at: 2025-09-29T19:22:33Z
--   models:
--     - moonshot/kimi-k3
--     - deepseek/deepseek-v4-pro
--   ---
--
-- `provider`/`model` is the combo to resume with; `created_at` records
-- when the session was created; `models` is the ordered history of every
-- combo actually used (most-recent-last). Token/cost totals are NOT
-- persisted here — they are ephemeral per-buffer state in the winbar.
-- pitel owns the block, so parsing is a few pattern matches,
-- not a YAML library; Neovim has no YAML parser and does not need one.
--
-- render() returns ONLY the `--- ... ---` block (no trailing blank line);
-- callers own the blank separator that follows it.

local M = {}

--- Parse a frontmatter block from a Lua list of lines. Returns
--- { provider, model, created_at, models = {combo,...} } or nil when there
--- is none (or it is unterminated). Tolerant on read: unknown keys and comments
--- are ignored, so a hand-edited block does not break resuming.
function M.parse(lines)
  if not lines or not lines[1] or not lines[1]:match("^%-%-%-%s*$") then
    return nil
  end
  local fm = { models = {} }
  local in_models = false
  for i = 2, #lines do
    local line = lines[i]
    if line:match("^%-%-%-%s*$") then
      return fm
    end
    if in_models then
      local item = line:match("^%s*%-%s*(.-)%s*$")
      if item and item ~= "" then
        fm.models[#fm.models + 1] = item
      end
    else
      local k, v = line:match("^(%S+):%s*(.-)%s*$")
      if k == "provider" then
        fm.provider = v
      elseif k == "model" then
        fm.model = v
      elseif k == "created_at" then
        fm.created_at = v
      elseif k == "models" then
        in_models = true
      end
    end
  end
  return nil -- unterminated
end

--- Render the frontmatter block for a combo + ordered history. The
--- returned table has no trailing blank line (see module comment).
function M.render(provider, model, models, created_at)
  local lines = { "---", "provider: " .. provider, "model: " .. model }
  if created_at then
    lines[#lines + 1] = "created_at: " .. created_at
  end
  if models and #models > 0 then
    lines[#lines + 1] = "models:"
    for _, c in ipairs(models) do
      lines[#lines + 1] = "  - " .. c
    end
  end
  lines[#lines + 1] = "---"
  return lines
end

return M
