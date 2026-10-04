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
local steer = state.steer

-- A compact, offbeat cycle of typographic marks. Teal, blue and violet
-- rotate independently to give the busy state a little extra life.
local SPINNER = {
  { "※", "BusyTeal" },
  { "⁕", "BusyBlue" },
  { "⁜", "BusyViolet" },
  { "⁑", "BusyTeal" },
}
local spinner_tick = 0
local spinner_timer = nil

-- Context-fill gauge: a minimum-width meter (in display cells) of filled
-- `█` blocks over a dim `░` track, with a partial eighth-block for the
-- tail so the fill reads continuously rather than snapping per cell. It
-- expands into otherwise-unused winbar width when the layout fits.
local GAUGE_MIN_W = 8
local GAUGE_EIGHTHS = { "▏", "▎", "▍", "▌", "▋", "▊", "▉" }

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

--- The un-truncated frontmatter description for a buffer, cached per
--- changedtick. The winbar re-evaluates on every screen draw, and the
--- description only changes when the buffer is edited, so re-reading and
--- re-parsing the frontmatter block each redraw is wasted work.
local desc_cache = {} -- buf -> { tick, full }

local function full_description(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = desc_cache[buf]
  if c and c.tick == tick then
    return c.full
  end
  local full
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 30, false)
  if lines[1] and lines[1]:match("^%-%-%-%s*$") then
    local fm = frontmatter.parse(lines)
    if fm and fm.description and fm.description ~= "" then
      full = fm.description
    end
  end
  desc_cache[buf] = { tick = tick, full = full }
  return full
end

--- The session description for the winbar, truncated to `max` display
--- columns so a long phrase cannot crowd out the right-hand usage/state
--- chips. The full description is cached (see full_description); only the
--- cheap width truncation runs per call.
local function winbar_description(buf, max)
  max = max or 40
  local d = full_description(buf)
  if not d then
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

-- Layout: a spinner beacon on the left (this buffer streaming, plus the
-- running tool's name once it has run 2s), then a global-session island,
-- then the current session's title/model/fold view; usage on the right —
-- the three chips, then an error glyph only when something went wrong. The
-- bar is width-aware: as the window narrows it drops the model/fold
-- cluster, then the chip costs, then the chip tokens; the error glyph, the
-- prices and the island survive. Past that the bar clips.
local function render_winbar(buf)
  local provider, model = util.current_combo(buf)
  local icons = require("harness").config.icons
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
      local frame = SPINNER[(spinner_tick % #SPINNER) + 1]
      local l = live and live[buf]
      if l and os.time() - l.since >= 2 then
        left[#left + 1] = seg(" " .. frame[1] .. " " .. l.name .. " " .. (os.time() - l.since) .. "s ", frame[2])
      else
        left[#left + 1] = seg(" " .. frame[1] .. " ", frame[2])
      end
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

  -- Context-fill gauge: filled blocks in a band color (green → amber →
  -- red as the window fills), a partial eighth-block for the tail, and a
  -- dim `░` track so the bar reads as a 0–100% meter.
  local function gauge_segments(pct, gauge_w)
    gauge_w = gauge_w or GAUGE_MIN_W
    local color = "GaugeLow"
    if pct >= 90 then
      color = "GaugeHigh"
    elseif pct >= 70 then
      color = "GaugeMid"
    end
    local filled = math.min(pct, 100) / 100 * gauge_w
    local full = math.floor(filled)
    local tail = math.max(0, math.min(7, math.floor((filled - full) * 8 + 0.5)))
    local fill = string.rep("█", full) .. (tail > 0 and GAUGE_EIGHTHS[tail] or "")
    local track = string.rep("░", gauge_w - full - (tail > 0 and 1 or 0))
    local out = {}
    if fill ~= "" then
      out[#out + 1] = { fill, color }
    end
    if track ~= "" then
      out[#out + 1] = { track, "GaugeEmpty" }
    end
    return out
  end

  -- Usage/cost cluster: three chips, each led by its config icon —
  -- since-open, all-time, context-fill. mode "full" shows tokens + cost,
  -- "compact" drops the cost, "prices" keeps only the two costs (the icons
  -- still disambiguate the two scopes). A chip is a list of part segments,
  -- so the context chip can lay the label, band-colored fill and dim track
  -- side by side in one contiguous run.
  local function usage_segment(mode, gauge_w)
    local chips = {} -- each chip: { { text, group }, ... }
    local u = vim.b[buf].yap_usage
    local s = vim.b[buf].yap_session_usage

    if u and (u.prompt > 0 or u.completion > 0) and mode ~= "prices" then
      local text = icons.since .. " " .. util.fmt_tokens(u.prompt + u.completion)
      if mode == "full" and u.cost then
        text = text .. " · " .. string.format("$%.4g", u.cost)
      end
      chips[#chips + 1] = { { text, "Idle" } }
    end

    if s and (s.prompt > 0 or s.completion > 0) and mode ~= "prices" then
      local text = icons.total .. " " .. util.fmt_tokens(s.prompt + s.completion)
      if mode == "full" and s.cost then
        text = text .. " · " .. string.format("$%.4g", s.cost)
      end
      chips[#chips + 1] = { { text, "Idle" } }
    end

    -- Context fill: the last turn's prompt tokens against the model's
    -- context window (both carried by the turn_end event), plus a fixed-
    -- width gauge whose fill color bands green → amber → red as it fills.
    local t = last_turn[buf]
    local ctx = t and tonumber(t.context_window) or nil
    if ctx and ctx > 0 and t.prompt and t.prompt > 0 and mode ~= "prices" then
      local pct = t.prompt / ctx * 100
      local pct_text = pct < 1 and string.format("%.1f%%", pct) or string.format("%.0f%%", pct)
      local parts = {
        { icons.ctx .. " " .. util.fmt_tokens(t.prompt) .. "/" .. util.fmt_tokens(ctx) .. " · " .. pct_text .. " ", "Idle" },
      }
      for _, g in ipairs(gauge_segments(pct, gauge_w)) do
        parts[#parts + 1] = g
      end
      chips[#chips + 1] = parts
    end

    if mode == "prices" then
      if u and u.cost then
        chips[#chips + 1] = { { icons.since .. " " .. string.format("$%.4g", u.cost), "Idle" } }
      end
      if s and s.cost then
        chips[#chips + 1] = { { icons.total .. " " .. string.format("$%.4g", s.cost), "Idle" } }
      end
    end

    if #chips == 0 then
      return nil
    end
    local segs = {}
    for ci, chip in ipairs(chips) do
      local prefix = ci == 1 and " " or " · "
      for pi, part in ipairs(chip) do
        segs[#segs + 1] = seg(pi == 1 and prefix .. part[1] or part[1], part[2])
      end
    end
    segs[#segs].text = segs[#segs].text .. " "
    return segs
  end

  -- Only an error gets a right-edge glyph: idle and "awaiting your reply"
  -- are self-evident from the absence of the left spinner, so they stay
  -- silent. The awaiting state still drives the OTHER-buffer rollup island.
  local function state_segment()
    if errors[buf] then
      return seg(" ✗ error ", "Error")
    end
    if steer[buf] then
      return seg(" ⌁ steer ", "Needs")
    end
    return nil
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
  -- model/fold → chip costs → chip tokens. The error glyph and the prices
  -- survive; past that the bar clips rather than hiding them.
  local desc_max, mode, show_mid = 40, "full", true
  while true do
    local left = left_segments(desc_max)
    local mid = show_mid and mid_segments() or {}
    local usage = usage_segment(mode)
    local state = state_segment()
    local total = width_of(left) + width_of(mid)
      + (usage and width_of(usage) or 0)
      + (state and width_of({ state }) or 0)
    if total <= width then
      -- Let the gauge consume all otherwise-unused winbar width; the `%=`
      -- separator already handles alignment between the left and right sides.
      if usage and mode ~= "prices" then
        usage = usage_segment(mode, GAUGE_MIN_W + math.max(0, width - total))
      end
      return render(left, mid, usage, state)
    end
    if show_mid then
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

--- Drop a buffer's cached description (BufWipeout). The changedtick check
--- already invalidates on buffer-number reuse; this releases the entry sooner.
function M.clear_desc(buf)
  desc_cache[buf] = nil
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
    250,
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
    GaugeEmpty = "NonText",
    GaugeLow = "DiagnosticOk",
    GaugeMid = "DiagnosticWarn",
    GaugeHigh = "DiagnosticError",
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, "Yap" .. name, { default = true, link = link })
  end
  vim.api.nvim_set_hl(0, "YapBusyTeal", { default = true, fg = "#5fd7c7" })
  vim.api.nvim_set_hl(0, "YapBusyBlue", { default = true, fg = "#7aa2f7" })
  vim.api.nvim_set_hl(0, "YapBusyViolet", { default = true, fg = "#bb9af7" })

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
