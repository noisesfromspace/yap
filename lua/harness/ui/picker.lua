-- Shared session-picker presentation: buffer state classification, the
-- state -> icon table, and the fixed-column icon prefix. Both the
-- open-session picker (harness.instances) and the saved-session picker
-- (harness.session .pick) render these, and the winbar rollup classifies
-- other sessions with the same precedence — so the rule lives here once.

local M = {}

local state = require("harness.state")
local config = require("harness.config")

--- Plain state token for a buffer: the key instances() filters on, and the
--- word behind each picker status glyph.
function M.state(buf)
  if state.running[buf] then
    return "running"
  elseif state.errors[buf] then
    return "error"
  elseif state.stopped[buf] then
    return "stopped"
  elseif state.awaiting[buf] then
    -- A finished subagent has already reported its answer back to the
    -- parent; it is done, not waiting for a reply.
    if vim.b[buf].yap_agent then
      return "done"
    end
    return "waiting"
  end
  return "idle"
end

--- The state -> icon table for the session pickers, mirroring the winbar
--- state chips.
function M.glyphs()
  local ic = config.defaults.icons
  return {
    running = ic.running,
    stopped = ic.stopped,
    error = ic.error,
    waiting = ic.waiting,
    done = ic.done,
    idle = ic.idle,
    approval = ic.approval,
  }
end

--- State glyph for a buffer, mirroring the winbar state chips. The picker is
--- static, so a fixed glyph stands in for the winbar's animated spinner; the
--- state word is omitted because the icon conveys it.
function M.status(buf)
  local glyph = M.glyphs()
  if state.pending_approvals[buf] then
    return glyph.approval
  end
  return glyph[M.state(buf)]
end

--- Widest display width among a set of icon strings (a map or list).
function M.icon_width(icons)
  local w = 0
  for _, icon in pairs(icons) do
    w = math.max(w, vim.fn.strdisplaywidth(icon))
  end
  return w
end

--- The fixed-column icon prefix: `icon` padded to `width`, then the
--- two-space gap before the title. An absent icon reserves the same column
--- so closed sessions align with open ones.
function M.prefix(icon, width)
  if not icon then
    return string.rep(" ", width + 2)
  end
  return icon .. string.rep(" ", width - vim.fn.strdisplaywidth(icon)) .. "  "
end

return M
