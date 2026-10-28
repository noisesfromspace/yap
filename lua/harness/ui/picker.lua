-- Shared session-picker presentation: buffer state classification, the
-- agent-role lookup, the state -> icon table, the typeable state tag, and the
-- fixed-column icon prefix. Both the open-session picker (harness.instances)
-- and the saved-session picker (harness.session .pick) render the icons, and
-- the winbar rollup classifies other sessions with the same precedence — so
-- the rule lives here once. The MiniPick buffer list uses tag() instead: there
-- the state is part of the item text, which is what a query filters on.

local M = {}

local state = require("harness.state")
local config = require("harness.config")

--- The agent role of a session, or nil for an ordinary conversation. A saved
--- session carries it in frontmatter; an open buffer also has the spawn-time
--- `yap_agent` var, which is set before the session file is first written.
function M.agent(fm, buf)
  local role = fm and fm.agent
  if (role == nil or role == "") and buf then
    role = vim.b[buf].yap_agent
  end
  return (role ~= nil and role ~= "") and role or nil
end

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
    if M.agent(nil, buf) then
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

-- The state word behind each buffer-picker tag. A picker filters on the item
-- text, so an icon is untypeable: the state must be spelled out for a query
-- like `[WAIT]` to find the sessions that need a reply.
local TAGS = {
  running = "RUN",
  stopped = "STOP",
  error = "ERR",
  waiting = "WAIT",
  done = "DONE",
  idle = "IDLE",
  approval = "APPR",
}

--- The widest tag, so every label's title starts at the same column.
M.tag_width = 0
for _, word in pairs(TAGS) do
  M.tag_width = math.max(M.tag_width, #word + 2)
end

--- The buffer picker's status tag: `[RUN]`, `[WAIT]`, … plus the padding that
--- puts every title in one column. The padding sits *after* the tag: a space
--- inside the brackets would break a typed query ([RUN] would no longer match
--- [RUN ]), while a contiguous tag matches. Returns the padded tag and the
--- tag's own width (for highlighting just the tag).
function M.tag(buf)
  local status = state.pending_approvals[buf] and "approval" or M.state(buf)
  local tag = "[" .. TAGS[status] .. "]"
  return tag .. string.rep(" ", M.tag_width - #tag + 1), #tag
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
