-- Winbar rendering — the self-evaluating `%!` statusline at the top of a
-- yap session buffer: busy beacon, global rollup island, session
-- description, provider/model + fold-view cluster, usage/cost chips and
-- the right-edge state glyph. Also owns the spinner that keeps the bar
-- redrawing while a turn streams; the spinner drains live tool output into
-- the tail buffers through state.drain_tail (set by the send path).

local M = {}

local state = require("harness.state")
local util = require("harness.util")
local frontmatter = require("harness.frontmatter")
local fold = require("harness.fold")

local running = state.running
local live = state.live
local errors = state.errors
local awaiting = state.awaiting
local last_turn = state.last_turn

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_tick = 0
local spinner_timer = nil

-- The winbar is a statusline: `%` starts a format item there, so any
-- literal `%` in segment text (the context-fill chip, a session title that
-- contains a percent sign) must be doubled. This runs on the content only —
-- the `%#…#` / `%*` highlight markers these helpers add are not escaped.
local function esc(text)
  return text:gsub("%%", "%%%%")
end

local function winbar_hl(text, group)
  return "%#Yap" .. group .. "#" .. esc(text) .. "%*"
end

-- Island segments share one raised background (`YapIsland`); each chip
-- keeps its own foreground via `YapIsland<Group>`. `%*` resets to the
-- WinBar default, so every island piece re-applies its own highlight.
local function island_hl(text, group)
  return "%#YapIsland" .. (group or "") .. "#" .. esc(text) .. "%*"
end

-- Last backend error per buffer; shown in the winbar until the next send.

-- The agent is awaiting the user's next prompt: set when a turn
-- completes (a `# @user` heading is appended), cleared when the user
-- sends. Drives the herdr-style "needs you" winbar state. A UI hint,
-- not conversation state (R1) — same drift tradeoff as yap_usage.

-- Data of the last completed turn per buffer (the binary's `turn_end`
-- event), handed to the User YapTurnDone autocmd. Ephemeral.

-- Other yap buffers in `set` (awaiting or running): the count for the
-- global overview/rollup chips. A tiny module map, so no buffer scans on
-- redraw (R10); stale entries are skipped via the validity check.
local function count_others(set, buf)
  local n = 0
  for b in pairs(set) do
    if b ~= buf and vim.api.nvim_buf_is_valid(b) and vim.b[b].yap then
      n = n + 1
    end
  end
  return n
end

-- Seed the awaiting hint for a reopened session from its content (R1):
-- it awaits the next reply when it has assistant history and ends on a
-- `# @user` heading. One-time scan at open, never on redraw.
function M.seed_awaiting(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local has_asst = false
  for _, l in ipairs(lines) do
    if l == "# @assistant" then
      has_asst = true
      break
    end
  end
  if not has_asst then
    awaiting[buf] = nil
    return
  end
  awaiting[buf] = nil
  for i = #lines, 1, -1 do
    if lines[i] == "# @user" then
      awaiting[buf] = true
      return
    elseif lines[i] == "# @assistant" then
      return
    end
  end
end

--- The session description for the winbar. A bounded read of the short
--- frontmatter block, so hand edits show up on the next redraw (the buffer
--- stays the source of truth); truncate to `max` display columns so a long
--- phrase cannot crowd out the right-hand usage/state chips.
local function winbar_description(buf, max)
  max = max or 40
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 30, false)
  if not lines[1] or not lines[1]:match("^%-%-%-%s*$") then
    return nil
  end
  local fm = frontmatter.parse(lines)
  local d = fm and fm.description
  if not d or d == "" then
    return nil
  end
  if vim.fn.strdisplaywidth(d) > max then
    local chars = math.min(vim.fn.strchars(d), math.max(1, max - 1))
    d = vim.fn.strcharpart(d, 0, chars)
    while vim.fn.strdisplaywidth(d .. "…") > max and chars > 1 do
      chars = chars - 1
      d = vim.fn.strcharpart(d, 0, chars)
    end
    d = d .. "…"
  end
  return d
end

-- Layout: a busy beacon and a global-session island on the left, then the
-- current session's title/model/fold view; activity on the right — usage
-- totals first, then the state glyph pinned to the far right edge so it
-- never moves as numbers grow. The bar is width-aware: as the window
-- narrows it drops the state glyph first (busy is duplicated by the left
-- beacon), then the model/fold cluster, then collapses the token phrase
-- (in→out), and finally shrinks the description. The island and the two
-- prices are the last things standing.
local function render_winbar(buf)
  local provider, model = util.current_combo(buf)
  local ok_w, width = pcall(vim.api.nvim_win_get_width, 0)
  if not ok_w or not width or width <= 0 then
    width = 999 -- no window context: render the full bar
  end

  local function seg(text, group, island)
    return { text = text, group = group, island = island }
  end
  local function render_seg(s)
    if s.island then
      return island_hl(s.text, s.group)
    end
    return winbar_hl(s.text, s.group or "Idle")
  end
  local function width_of(segs)
    local n = 0
    for _, s in ipairs(segs) do
      n = n + vim.fn.strdisplaywidth(s.text)
    end
    return n
  end

  -- Mandatory left cluster (never dropped; the description shrinks).
  local function left_segments(desc_max)
    local left = {}
    if running and running[buf] then
      left[#left + 1] = seg(" ▶ ", "Busy")
    end
    local running_others_n = count_others(running, buf)
    local others = count_others(awaiting, buf)
    if running_others_n > 0 or others > 0 then
      left[#left + 1] = seg(" ", nil, true)
      if running_others_n > 0 then
        left[#left + 1] = seg("▶" .. running_others_n, "Busy", true)
      end
      if running_others_n > 0 and others > 0 then
        left[#left + 1] = seg(" │ ", nil, true)
      end
      if others > 0 then
        left[#left + 1] = seg("◉" .. others, "Needs", true)
      end
      left[#left + 1] = seg(" ", nil, true)
    end
    local desc = winbar_description(buf, desc_max)
    if desc then
      left[#left + 1] = seg(" " .. desc, "Description")
      left[#left + 1] = seg(" · ", "Idle")
    end
    return left
  end

  -- Droppable middle: provider/model and the applied fold view.
  local function mid_segments()
    return {
      seg(provider .. "/" .. model, "Model"),
      seg(" · Ⓕ" .. fold.level() .. " ", "Idle"),
    }
  end

  -- Usage/cost cluster. mode: "full" (tokens + both prices), "compact"
  -- (in→out tokens + both prices), "prices" (both prices only). The first
  -- $ is this buffer's accumulated cost; Σ is the all-time session cost
  -- from the audit log. Returns a list of segments so the context-fill
  -- chip can carry its own highlight.
  local function usage_segment(mode)
    local items = {} -- { text, group }
    local u = vim.b[buf].yap_usage
    local s = vim.b[buf].yap_session_usage
    if u and (u.prompt > 0 or u.completion > 0) and mode ~= "prices" then
      if mode == "full" then
        items[#items + 1] = {
          util.fmt_tokens(u.prompt) .. " in · " .. util.fmt_tokens(u.completion) .. " out",
          "Idle",
        }
      else
        items[#items + 1] = { util.fmt_tokens(u.prompt) .. "→" .. util.fmt_tokens(u.completion), "Idle" }
      end
    end
    -- Context fill: the last turn's prompt tokens against the model's
    -- context window (both carried by the turn_end event). A near-full
    -- window is a safety signal, so it gets the warning color.
    local t = last_turn[buf]
    local ctx = t and tonumber(t.context_window) or nil
    if ctx and ctx > 0 and t.prompt and t.prompt > 0 then
      local pct = math.floor(t.prompt / ctx * 100 + 0.5)
      items[#items + 1] = { pct .. "% ctx", pct >= 90 and "Needs" or "Idle" }
    end
    if u and u.cost then
      items[#items + 1] = { string.format("$%.4g", u.cost), "Idle" }
    end
    if s and s.cost then
      items[#items + 1] = { (mode == "full" and "total " or "Σ") .. string.format("$%.4g", s.cost), "Idle" }
    end
    if #items == 0 then
      return nil
    end
    local segs = { seg(" " .. items[1][1], items[1][2]) }
    for i = 2, #items do
      segs[#segs + 1] = seg(" · " .. items[i][1], items[i][2])
    end
    segs[#segs].text = segs[#segs].text .. " "
    return segs
  end

  local function state_segment()
    if running and running[buf] then
      local frame = SPINNER[(spinner_tick % #SPINNER) + 1]
      local l = live and live[buf]
      local state = l and (frame .. " " .. l.name .. " " .. (os.time() - l.since) .. "s") or (frame .. " busy")
      return seg(" " .. state .. " ", "Busy")
    elseif errors[buf] then
      return seg(" ✗ error ", "Error")
    elseif awaiting[buf] then
      return seg(" ◉ waiting ", "Needs")
    else
      return seg(" ○ idle ", "Idle")
    end
  end

  local function render(left, mid, usage, state)
    local parts = {}
    for _, s in ipairs(left) do
      parts[#parts + 1] = render_seg(s)
    end
    for _, s in ipairs(mid) do
      parts[#parts + 1] = render_seg(s)
    end
    parts[#parts + 1] = "%="
    if usage then
      for _, s in ipairs(usage) do
        parts[#parts + 1] = render_seg(s)
      end
    end
    if state then
      parts[#parts + 1] = render_seg(state)
    end
    return table.concat(parts, "")
  end

  -- Degrade until the bar fits, dropping the least important parts first:
  -- state glyph → model/fold → token phrase → description. Prices and the
  -- island survive; past that the bar clips rather than hiding prices.
  local desc_max, mode, show_mid, show_state = 40, "full", true, true
  while true do
    local left = left_segments(desc_max)
    local mid = show_mid and mid_segments() or {}
    local usage = usage_segment(mode)
    local state = show_state and state_segment() or nil
    local total = width_of(left) + width_of(mid)
      + (usage and width_of(usage) or 0)
      + (state and width_of({ state }) or 0)
    if total <= width then
      return render(left, mid, usage, state)
    end
    if show_state then
      show_state = false
    elseif show_mid then
      show_mid = false
    elseif mode == "full" then
      mode = "compact"
    elseif mode == "compact" then
      mode = "prices"
    elseif desc_max > 15 then
      desc_max = desc_max - 5
    else
      return render(left, mid, usage, state) -- smallest layout; let it clip
    end
  end
end

--- Winbar expression: the winbar is set to a self-evaluating `%!` call of
--- this function, so it always reflects current buffer state on redraw —
--- no imperative refresh calls anywhere.
function M.winbar(buf)
  buf = buf or tonumber(vim.g.actual_curbuf) or vim.api.nvim_get_current_buf()
  return render_winbar(buf)
end

--- The herdr-style rollup for a statusline/tabline: `◉N` when N OTHER
--- yap buffers await the user's reply, "" otherwise. The winbar shows
--- the same chip, so this is the reusable segment for global visibility.
function M.overview(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local n = count_others(awaiting, buf)
  return n > 0 and ("◉" .. n) or ""
end

function M.spinner_stop_if_idle()
  if spinner_timer and not next(running) then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
end

function M.spinner_start()
  if spinner_timer then
    return
  end
  spinner_timer = vim.uv.new_timer()
  spinner_timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      spinner_tick = spinner_tick + 1
      for b in pairs(running) do
        state.drain_tail(b) -- pull new tool output into the tail buffers
      end
      vim.cmd.redrawstatus() -- re-evaluates the winbar expression
      M.spinner_stop_if_idle()
    end)
  )
end

local function define_winbar_hl()
  local links = {
    Model = "Keyword",
    Description = "Title",
    Busy = "DiagnosticOk",
    Idle = "Comment",
    Error = "DiagnosticError",
    Needs = "DiagnosticWarn",
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, "Yap" .. name, { default = true, link = link })
  end

  -- The island is a raised pill: a theme-aware background (NormalFloat,
  -- falling back to Visual) with the chip foregrounds pulled from the
  -- linked groups above so user `:hi YapBusy` overrides still win.
  local function attr(group, key)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and hl and hl[key] then
      return hl[key]
    end
  end
  local bg = attr("NormalFloat", "bg") or attr("Visual", "bg")
  local fg = attr("WinBar", "fg") or attr("StatusLine", "fg")
  vim.api.nvim_set_hl(0, "YapIsland", { default = true, fg = fg, bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandBusy", { default = true, fg = attr("YapBusy", "fg"), bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandNeeds", { default = true, fg = attr("YapNeeds", "fg"), bg = bg })
end

define_winbar_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("YapWinbarHl", { clear = true }),
  callback = define_winbar_hl,
})

return M
