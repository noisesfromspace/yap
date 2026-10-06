-- Winbar rendering — the self-evaluating `%!` statusline at the top of a
-- yap session buffer: busy beacon (or the buffer's own state icon), global
-- rollup island, session description, provider/model island and usage/cost
-- chips. Usage/cost chips remain on the right. The spinner only redraws the
-- display while the turn is running; the audit poll owns live tool output.

local M = {}

local state = require("harness.state")
local util = require("harness.util")
local frontmatter = require("harness.frontmatter")

local running = state.running
local live = state.live
local errors = state.errors
local stopped = state.stopped
local awaiting = state.awaiting
local steer = state.steer
local sessions = state.sessions

-- Local LCG so the shimmer never reseeds the global math.random other
-- plugins rely on; seeded from the monotonic clock at load.
local rng_state = math.floor(vim.uv.hrtime() % 2 ^ 31) + 1
local function pick(t)
  rng_state = (rng_state * 1664525 + 1013904223) % 2 ^ 32
  return t[rng_state % #t + 1]
end

-- Mood ring: the busy beacon wanders in little emotional arcs, independent
-- of task duration. Each arc leaves the middle for a random extreme, pauses,
-- then returns; faces shimmer within the current pool on every spinner tick.
-- The pools use solid single-cell Font Awesome faces so the Ember tint still
-- applies (the hollow smile/frown/meh triad is deliberately omitted).
local function nf(cp)
  return vim.fn.nr2char(cp)
end
local NF_MOOD_RING = {
  {
    faces = {
      nf(0xEDA9),
      nf(0xEE80),
      nf(0xEE49),
      nf(0xEE4B),
      nf(0xEE4E),
      nf(0xEE50),
      nf(0xEE62),
      nf(0xEE63),
      nf(0xEE64),
      nf(0xEE65),
    },
  }, -- smile-wink, smile-beam, grin, grin-beam, grin-squint, grin-stars, laugh, laugh-beam, laugh-squint, laugh-wink
  {
    faces = {
      nf(0xEE4A),
      nf(0xEE55),
      nf(0xEE4D),
      nf(0xEE52),
      nf(0xEE54),
      nf(0xEE53),
      nf(0xEE5F),
      nf(0xEE60),
      nf(0xEE61),
      nf(0xEE51),
      nf(0xEE4F),
    },
  }, -- grin-wide, grin-wink, grin-hearts, grin-tongue, grin-tongue-wink, grin-tongue-squint, kiss, kiss-beam, kiss-wink-heart, grin-tears, grin-squint-tears
  { faces = { nf(0xEE89), nf(0xEE4C), nf(0xEE6E), nf(0xEE42), nf(0xEE6D) } }, -- surprise, grin-beam-sweat, rolling-eyes, flushed, meh-blank
  { faces = { nf(0xEE42), nf(0xEE48), nf(0xEE8F), nf(0xEE43), nf(0xEE6D), nf(0xEE6E) } }, -- flushed, grimace, tired, frown-open, meh-blank, rolling-eyes
  { faces = { nf(0xEE8F), nf(0xEE48), nf(0xEE43), nf(0xEE1F), nf(0xEE7C) } }, -- tired, grimace, frown-open, angry, sad-tear
  { faces = { nf(0xEE30), nf(0xEE7B), nf(0xEE7C), nf(0xEE1F), nf(0xEE8F), nf(0xEE48) } }, -- dizzy, sad-cry, sad-tear, angry, tired, grimace
}
local PLAIN_SPINNER_FRAMES = { "※", "⁕", "⁜", "⁑", "✳", "✦", "✧", "⋆", "⁂" }
-- Busy color: a continuous smoothstep tween around the Ember triad
-- (amber → coral → rose). Fixed synthetic hues, never derived from the
-- theme, so an achromatic colorscheme cannot wash the beacon out.
local BUSY_RGB = {
  { 235 / 255, 201 / 255, 132 / 255 }, -- amber
  { 235 / 255, 149 / 255, 132 / 255 }, -- coral
  { 235 / 255, 132 / 255, 175 / 255 }, -- rose
}
local BUSY_CYCLE_S = 3 -- seconds per full loop through the triad
local spin_start = vim.uv.hrtime()

local function busy_color()
  local t = ((vim.uv.hrtime() - spin_start) / 1e9 % BUSY_CYCLE_S) / BUSY_CYCLE_S
  local n = #BUSY_RGB
  local scaled = t * n
  local i = math.floor(scaled) % n + 1
  local j = i % n + 1
  local f = scaled % 1
  f = f * f * (3 - 2 * f) -- smoothstep: ease into and out of each stop
  local a, b = BUSY_RGB[i], BUSY_RGB[j]
  local function lerp(x, y)
    return x + (y - x) * f
  end
  return string.format(
    "#%02x%02x%02x",
    math.floor(lerp(a[1], b[1]) * 255 + 0.5),
    math.floor(lerp(a[2], b[2]) * 255 + 0.5),
    math.floor(lerp(a[3], b[3]) * 255 + 0.5)
  )
end

M.spinner_frames = {} -- exported for tests: every face the beacon can show
for _, b in ipairs(NF_MOOD_RING) do
  for _, g in ipairs(b.faces) do
    M.spinner_frames[#M.spinner_frames + 1] = g
  end
end
local plain_spinner_glyph = PLAIN_SPINNER_FRAMES[1]
local spinner_timer = nil

-- Mood changes on the spinner tick, never on redraw or tool elapsed time.
-- Seven ticks per step (~1.3s); longer rests in the middle, short dramatic
-- pauses at either extreme. A new run starts in the middle again.
local spin_tick = 0
local MOOD_CENTER = 3
local mood_bucket = MOOD_CENTER
local mood_target = nil
local mood_next_tick = 0
local mood_cache = { tick = -1, glyph = nil }

local function advance_mood()
  if spin_tick < mood_next_tick then
    return
  end
  if not mood_target then
    mood_target = pick({ 1, #NF_MOOD_RING })
  end
  if mood_bucket ~= mood_target then
    mood_bucket = mood_bucket + (mood_bucket < mood_target and 1 or -1)
    mood_next_tick = spin_tick + 7
    if mood_bucket == mood_target then
      mood_target = MOOD_CENTER
      mood_next_tick = spin_tick + pick({ 5, 8, 11 })
    end
  else
    mood_target = nil
    mood_next_tick = spin_tick + pick({ 15, 23, 31 })
  end
end

local function mood_glyph()
  if mood_cache.tick ~= spin_tick then
    mood_cache = { tick = spin_tick, glyph = pick(NF_MOOD_RING[mood_bucket].faces) }
  end
  return mood_cache.glyph
end

-- Context meter: a fixed-width, eight-cell bar. Keeping its width
-- independent of the window layout avoids redraw/reflow surprises.
local GAUGE_W = 8
local GAUGE_EIGHTHS = { "▏", "▎", "▍", "▌", "▋", "▊", "▉" }

-- The winbar is a statusline: `%` starts a format item there, so any
-- literal `%` in segment text (a session title that contains a percent sign)
-- must be doubled. This runs on the content only — the `%#…#` / `%*`
-- highlight markers these helpers add are not escaped.
local function esc(text)
  return text:gsub("%%", "%%%%")
end

local function winbar_hl(text, group)
  return "%#Yap" .. group .. "#" .. esc(text) .. "%*"
end

-- Island segments share one raised background (`YapIsland`); each chip
-- keeps its own foreground via `YapIsland<Group>`. `%*` resets to the
-- WinBar default, so every island piece re-applies its own highlight.
local function island_hl(text, group, style)
  return "%#YapIsland" .. (style or "") .. (group or "") .. "#" .. esc(text) .. "%*"
end

-- Last backend error per buffer; shown in the winbar until the next send.

-- The agent is awaiting the user's next prompt: set when a turn
-- completes (a `# @user` heading is appended), cleared when the user
-- sends. Drives the herdr-style "needs you" winbar state. A UI hint,
-- not conversation state (R1) — same drift tradeoff as yap_usage.

-- Data of the last completed turn per buffer (the binary's `turn_end`
-- event), handed to the User YapTurnDone autocmd. Ephemeral.

-- Other yap sessions (every buffer in `state.sessions` except the current
-- one, with subagents folded into their parent) classified into the five
-- picker states. Iterating a tiny module map, not a full buffer scan, keeps
-- the winbar cheap on every redraw; stale entries are skipped via the
-- validity check.
local function other_session_counts(buf)
  local counts = { running = 0, waiting = 0, stopped = 0, error = 0, idle = 0 }
  for b in pairs(sessions) do
    if b ~= buf and vim.api.nvim_buf_is_valid(b) and vim.b[b].yap and not vim.b[b].yap_subagent_parent then
      if running[b] then
        counts.running = counts.running + 1
      elseif errors[b] then
        counts.error = counts.error + 1
      elseif stopped[b] then
        counts.stopped = counts.stopped + 1
      elseif awaiting[b] then
        counts.waiting = counts.waiting + 1
      else
        counts.idle = counts.idle + 1
      end
    end
  end
  return counts
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

local function truncate_display(text, max)
  if vim.fn.strdisplaywidth(text) <= max then
    return text
  end
  local chars = math.min(vim.fn.strchars(text), math.max(1, max - 1))
  local truncated = vim.fn.strcharpart(text, 0, chars)
  while vim.fn.strdisplaywidth(truncated .. "…") > max and chars > 1 do
    chars = chars - 1
    truncated = vim.fn.strcharpart(text, 0, chars)
  end
  return truncated .. "…"
end

--- The session description for the winbar, truncated to `max` display
--- columns so a long phrase cannot crowd out the right-hand usage/state
--- chips. The full description is cached (see full_description); only the
--- cheap width truncation runs per call.
local function winbar_description(buf, max)
  local d = full_description(buf)
  return d and truncate_display(d, max or 40) or nil
end

-- Layout: a spinner beacon on the left (this buffer streaming, plus the
-- running tool's name once it has run 2s) or this buffer's state icon
-- (stopped/error/waiting/idle), then a global-session rollup island, then
-- the description on the left; a centered provider/model island; usage
-- counters and context meter on the right. As the window narrows the
-- center island drops, then costs, then tokens; prices and the context
-- meter survive. Past that the bar clips.
local function render_winbar(buf)
  local provider, model = util.current_combo(buf)
  local icons = require("harness").config.icons
  local win = tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
  local inactive = win ~= vim.api.nvim_get_current_win()
  local ok_w, width = pcall(vim.api.nvim_win_get_width, win)
  if not ok_w or not width or width <= 0 then
    width = 999 -- no window context: render the full bar
  end
  -- The gutter is the line-number/sign/fold column band before the text; the
  -- state icon is centered in it, so the session content starts flush with
  -- the text. textoff is the live column count for the target window.
  local gutter = 0
  local ok_g, wins = pcall(vim.fn.getwininfo, win)
  if ok_g and wins and wins[1] then
    gutter = wins[1].textoff or 0
  end

  local function seg(text, group, island, cursive)
    return { text = text, group = group, island = island, cursive = cursive }
  end
  local function render_seg(s, upright)
    if s.group == "IslandCap" then
      return winbar_hl(s.text, inactive and "IslandCapNC" or "IslandCap")
    end
    local style = s.cursive and "Cursive" or (upright and "Upright" or nil)
    if s.island then
      return island_hl(s.text, s.group, style)
    end
    return winbar_hl(s.text, (style or "") .. (s.group or "Idle"))
  end
  local function width_of(segs)
    local n = 0
    for _, s in ipairs(segs) do
      n = n + vim.fn.strdisplaywidth(s.text)
    end
    return n
  end

  -- Mandatory left cluster (never dropped; the description shrinks). Build
  -- logical items first, with breathing room between sections rather than
  -- repeated dividers. The rollup uses lualine's bubbles-style rounded caps.
  local function left_segments(desc_max)
    local left = {}
    local has_item = false
    local function add_item(item)
      -- The first item sits flush at the text edge; later items get a
      -- two-column gap. The gutter prefix is appended separately below.
      if has_item then
        left[#left + 1] = seg("  ", "Idle")
      end
      for _, s in ipairs(item) do
        left[#left + 1] = s
      end
      has_item = true
    end

    -- The buffer's own state is a one-cell icon centered in the gutter (the
    -- line-number, sign and fold columns). Session content — tool text, the
    -- rollup island and the description — starts flush at the text edge. The
    -- animated busy beacon only shows while the session is active; an
    -- inactive session drops it (a generating session needs no attention) but
    -- keeps its state icon, so a waiting/errored/stopped/idle session stays
    -- visible at a glance from another window.
    local icon, icon_group = nil, nil
    local spinner = running and running[buf]
    if not inactive and spinner then
      icon = require("harness").config.nerd_font and mood_glyph() or plain_spinner_glyph
      icon_group = "BusySpin"
    elseif not spinner then
      if errors[buf] then
        icon, icon_group = icons.error, "Error"
      elseif stopped[buf] then
        icon, icon_group = icons.stopped, "Needs"
      elseif steer[buf] then
        icon, icon_group = icons.steer, "Needs"
      elseif awaiting[buf] then
        icon, icon_group = icons.waiting, "Needs"
      else
        icon, icon_group = icons.idle, "Idle"
      end
    end

    local gutter_trail_seg = nil
    if gutter > 0 then
      local lead = math.floor((gutter - 1) / 2)
      left[#left + 1] = seg(string.rep(" ", lead), "Idle")
      if icon then
        left[#left + 1] = seg(icon, icon_group)
      end
      local trail = gutter - lead - (icon and 1 or 0)
      if trail > 0 then
        gutter_trail_seg = seg(string.rep(" ", trail), "Idle")
        left[#left + 1] = gutter_trail_seg
      end
    elseif icon then
      -- No gutter (e.g. line numbers off): the icon is the leftmost item.
      add_item({ seg(icon, icon_group) })
    end

    -- Tool text and steering belong to the text region, ahead of the rollup.
    if not inactive and spinner then
      local l = live and live[buf]
      if l and os.time() - l.since >= 2 then
        add_item({ seg(l.name .. " " .. (os.time() - l.since) .. "s", "BusyText") })
      end
      if steer[buf] then
        add_item({ seg(icons.steer, "Needs") })
      end
    end

    -- The rollup island totals every OTHER session by state. It is the
    -- active session's dashboard, not this window's own signal, so an
    -- inactive window hides it entirely: the only thing a background
    -- session is allowed to advertise is its own leftmost state icon.
    if not inactive then
      local counts = other_session_counts(buf)
      local order = {
        { icons.running, counts.running, "Busy" },
        { icons.waiting, counts.waiting, "Needs" },
        { icons.stopped, counts.stopped, "Needs" },
        { icons.error, counts.error, "Error" },
        { icons.idle, counts.idle, "Idle" },
      }
      local rollup = { seg(icons.cap_l, "IslandCap"), seg(" ", nil, true) }
      local first = true
      for _, chip in ipairs(order) do
        if chip[2] > 0 then
          if not first then
            rollup[#rollup + 1] = seg("  ", nil, true)
          end
          rollup[#rollup + 1] = seg(chip[1] .. chip[2], chip[3], true)
          first = false
        end
      end
      if not first then
        rollup[#rollup + 1] = seg(" ", nil, true)
        rollup[#rollup + 1] = seg(icons.cap_r, "IslandCap")
        -- Let the island's left cap overhang one cell into the gutter when the
        -- island is the leftmost content (no tool text ahead of it) and the
        -- gutter is more than 3 columns wide, so there is padding to spare. The
        -- state icon stays centered; only the trailing gutter padding is reclaimed.
        if gutter > 3 and gutter_trail_seg and not has_item then
          if #gutter_trail_seg.text > 1 then
            gutter_trail_seg.text = gutter_trail_seg.text:sub(1, #gutter_trail_seg.text - 1)
          else
            table.remove(left)
          end
        end
        add_item(rollup)
      end
    end

    local desc = not inactive and winbar_description(buf, desc_max) or nil
    if desc then
      add_item({ seg(desc, "Description", false, true) })
    end

    if has_item then
      left[#left + 1] = seg(" ", "Idle")
    end
    return left
  end

  -- Fixed-width context meter: percentage plus an eight-cell bar. In the
  -- narrowest layout, the percentage is dropped but the complete bar stays.
  local function context_segment(show_percent)
    local t = state.live_usage[buf] or state.last_turn[buf]
    local ctx = t and tonumber(t.context_window) or nil
    local prompt = t and tonumber(t.context_prompt or t.prompt) or nil
    if not ctx or ctx <= 0 or not prompt or prompt <= 0 then
      return nil
    end

    local pct = math.min(prompt / ctx * 100, 100)
    local fill, track
    if require("harness").config.nerd_font then
      -- Nerd Font's progress cells have rounded ends but no fractional cell.
      local cells = math.floor(pct / 100 * GAUGE_W + 0.5)
      fill = ""
      track = ""
      local glyph = {
        left = { "", "" },
        mid = { "", "" },
        right = { "", "" },
      }
      for i = 1, GAUGE_W do
        local edge = i == 1 and "left" or (i == GAUGE_W and "right" or "mid")
        if i <= cells then
          fill = fill .. glyph[edge][2]
        else
          track = track .. glyph[edge][1]
        end
      end
    else
      local eighths = math.floor(pct / 100 * GAUGE_W * 8 + 0.5)
      local full = math.floor(eighths / 8)
      local tail = eighths % 8
      fill = string.rep("█", full) .. (tail > 0 and GAUGE_EIGHTHS[tail] or "")
      track = string.rep("░", GAUGE_W - full - (tail > 0 and 1 or 0))
    end
    local color = pct >= 90 and "GaugeHigh" or (pct >= 70 and "GaugeMid" or "GaugeLow")
    local parts = {}
    if show_percent then
      local text = pct < 1 and string.format("%.1f%% ", pct) or string.format("%.0f%% ", pct)
      parts[#parts + 1] = { " ", "GaugeEmpty", true }
      parts[#parts + 1] = { text, "GaugeLabel", true }
    else
      parts[#parts + 1] = { " ", "GaugeEmpty", true }
    end
    if fill ~= "" then
      parts[#parts + 1] = { fill, color, true }
    end
    if track ~= "" then
      parts[#parts + 1] = { track, "GaugeEmpty", true }
    end
    parts[#parts + 1] = { " ", "GaugeEmpty", true }
    return parts
  end

  -- Usage counters and context meter stay right-aligned.
  -- As the bar narrows, costs and tokens drop before the context meter.
  local function usage_segment(mode)
    local chips = {} -- each chip: { { text, group }, ... }
    local live = state.live_usage[buf]
    local function include_live(base)
      if not live then
        return base
      end
      base = base or { prompt = 0, completion = 0 }
      return {
        prompt = base.prompt + (live.prompt or 0),
        completion = base.completion + (live.completion or 0),
        cost = (base.cost or 0) + (live.cost or 0),
      }
    end
    local u = include_live(vim.b[buf].yap_usage)
    local s = include_live(vim.b[buf].yap_session_usage)
    -- When both counters represent the same token total, the since-open
    -- chip adds no information; keep the session's all-time chip only.
    if u and s and (s.prompt + s.completion) > 0 and (u.prompt + u.completion) == (s.prompt + s.completion) then
      u = nil
    end

    if (mode == "full" or mode == "compact") and u and (u.prompt > 0 or u.completion > 0) then
      local text = icons.since .. " " .. util.fmt_tokens(u.prompt + u.completion)
      if mode == "full" and u.cost then
        text = text .. " · " .. string.format("$%.4g", u.cost)
      end
      chips[#chips + 1] = { { text, "Idle" } }
    end

    if (mode == "full" or mode == "compact") and s and (s.prompt > 0 or s.completion > 0) then
      local text = icons.total .. " " .. util.fmt_tokens(s.prompt + s.completion)
      if mode == "full" and s.cost then
        text = text .. " · " .. string.format("$%.4g", s.cost)
      end
      chips[#chips + 1] = { { text, "Idle" } }
    end

    if mode == "prices" then
      if u and u.cost then
        chips[#chips + 1] = { { icons.since .. " " .. string.format("$%.4g", u.cost), "Idle" } }
      end
      if s and s.cost then
        chips[#chips + 1] = { { icons.total .. " " .. string.format("$%.4g", s.cost), "Idle" } }
      end
    end

    local context = context_segment(mode ~= "gauge")
    if #chips == 0 and not context then
      return nil
    end
    local segs = {}
    local function pill(parts)
      segs[#segs + 1] = seg(" ", "Idle")
      segs[#segs + 1] = seg("", "IslandCap")
      for _, part in ipairs(parts) do
        segs[#segs + 1] = seg(part[1], part[2], true, part[2] == "Model")
      end
      segs[#segs + 1] = seg("", "IslandCap")
    end
    if #chips > 0 then
      local counters = { { " ", "Count" } }
      for ci, chip in ipairs(chips) do
        if ci > 1 then
          counters[#counters + 1] = { "  ", "Count" }
        end
        for _, part in ipairs(chip) do
          counters[#counters + 1] = { part[1], "Count" }
        end
      end
      counters[#counters + 1] = { " ", "Count" }
      pill(counters)
    end
    if context then
      pill(context)
    end
    segs[#segs + 1] = seg(" ", "Idle")
    return segs
  end

  -- The model island is centered independently of left and right content.
  -- Inactive sessions show their session identity instead of a model that is
  -- only useful while that session is selected.
  local function center_segments()
    local text = provider .. "/" .. model
    if inactive then
      local label = require("harness.session").label(vim.b[buf].yap_path, full_description(buf))
      text = truncate_display(label, 40)
    end
    return {
      seg(" ", "Idle"),
      seg("", "IslandCap"),
      seg(" ", "Count", true),
      seg(text, "Model", true, true),
      seg(" ", "Count", true),
      seg("", "IslandCap"),
      seg(" ", "Idle"),
    }
  end

  -- The state icon now lives on the left (see left_segments); the right
  -- side keeps only the usage counters and the context meter.

  local function render(left, center, usage, left_width, right_width)
    local parts = {}
    for _, s in ipairs(left) do
      parts[#parts + 1] = render_seg(s)
    end
    -- `%=` centers the island between the two side clusters, not at the
    -- window's midpoint, so an asymmetric pair (a fresh session has no
    -- gauge yet) drifts off center. Pad the narrower side so both are
    -- equal width and the island lands on the true midpoint.
    if center and left_width < right_width then
      parts[#parts + 1] = string.rep(" ", right_width - left_width)
    end
    parts[#parts + 1] = "%="
    if center then
      for _, s in ipairs(center) do
        parts[#parts + 1] = render_seg(s, true)
      end
      parts[#parts + 1] = "%="
      if right_width < left_width then
        parts[#parts + 1] = string.rep(" ", left_width - right_width)
      end
    end
    if usage then
      for _, s in ipairs(usage) do
        parts[#parts + 1] = render_seg(s, true)
      end
    end
    return table.concat(parts, "")
  end

  -- Preserve real centering: drop the middle when either edge cluster
  -- would collide with it, then degrade the right side as before.
  local desc_max, mode, show_mid = 40, "full", true
  while true do
    local left = left_segments(desc_max)
    local center = show_mid and center_segments() or nil
    local usage = not inactive and usage_segment(mode)
    local left_width = width_of(left)
    local right_width = usage and width_of(usage) or 0
    local center_width = center and width_of(center) or 0
    local total = left_width + center_width + right_width
    if
      total <= width
      and (
        not center
        or (
          left_width <= math.floor((width - center_width) / 2)
          and right_width <= math.floor((width - center_width) / 2)
        )
      )
    then
      return render(left, center, usage, left_width, right_width)
    end
    if show_mid then
      show_mid = false
    elseif mode == "full" then
      mode = "compact"
    elseif mode == "compact" then
      mode = "prices"
    elseif mode == "prices" and context_segment(false) then
      mode = "gauge"
    elseif desc_max > 15 then
      desc_max = desc_max - 5
    else
      return render(left, nil, usage, left_width, right_width) -- smallest layout; let it clip
    end
  end
end

--- Winbar expression: the winbar is set to a self-evaluating `%!` call of
--- this function, so it always reflects current buffer state on redraw —
--- no imperative refresh calls anywhere.
function M.winbar(buf)
  if buf == nil then
    -- The %! expression is evaluated in the current window/buffer context,
    -- even when drawing another window's bar; g:actual_curbuf is only set for
    -- %{} items. g:statusline_winid is the only thing that identifies the
    -- window being drawn, so resolve the buffer from it — falling back to the
    -- current buffer for direct (non-statusline) calls.
    local win = tonumber(vim.g.statusline_winid)
    if win and vim.api.nvim_win_is_valid(win) then
      buf = vim.api.nvim_win_get_buf(win)
    end
  end
  buf = buf or vim.api.nvim_get_current_buf()
  return render_winbar(buf)
end

--- Drop a buffer's cached description (BufWipeout). The changedtick check
--- already invalidates on buffer-number reuse; this releases the entry sooner.
function M.clear_desc(buf)
  desc_cache[buf] = nil
end

--- The herdr-style rollup for a statusline/tabline: `<waiting icon>N` when
--- N OTHER yap buffers await the user's reply, "" otherwise. The winbar
--- shows the same chip, so this is the reusable segment for global
--- visibility.
function M.overview(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local n = other_session_counts(buf).waiting
  return n > 0 and (require("harness").config.icons.waiting .. n) or ""
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
  mood_bucket = MOOD_CENTER
  mood_target = nil
  mood_next_tick = spin_tick + pick({ 15, 23, 31 })
  mood_cache.tick = -1
  spinner_timer = vim.uv.new_timer()
  spinner_timer:start(
    0,
    180,
    vim.schedule_wrap(function()
      spin_tick = spin_tick + 1
      advance_mood()
      plain_spinner_glyph = pick(PLAIN_SPINNER_FRAMES)
      local c = busy_color()
      vim.api.nvim_set_hl(0, "YapBusySpin", { fg = c })
      vim.api.nvim_set_hl(0, "YapBusyText", { fg = c, italic = true })
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
    Done = "DiagnosticOk",
    Idle = "Comment",
    Error = "DiagnosticError",
    Needs = "DiagnosticWarn",
    GaugeEmpty = "NonText",
    GaugeLabel = "Keyword",
    GaugeLow = "DiagnosticOk",
    GaugeMid = "DiagnosticWarn",
    GaugeHigh = "DiagnosticError",
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, "Yap" .. name, { default = true, link = link })
  end
  -- The busy beacon and its tool text share one live-updated color, so the
  -- animated face and "bash 12s" tint in lockstep; the tick re-tints both.
  local busy = busy_color()
  vim.api.nvim_set_hl(0, "YapBusySpin", { default = true, fg = busy })
  vim.api.nvim_set_hl(0, "YapBusyText", { default = true, fg = busy, italic = true })
  -- The island is a raised pill: a theme-aware background (NormalFloat,
  -- falling back to Visual) with the chip foregrounds pulled from the
  -- linked groups above so user `:hi YapBusy` overrides still win.
  local function attr(group, key)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and hl and hl[key] then
      return hl[key]
    end
  end
  local bg = attr("NormalFloat", "bg") or attr("Visual", "bg") or attr("Normal", "bg")
  local bar_bg = attr("WinBar", "bg") or attr("Normal", "bg")
  local inactive_bg = attr("WinBarNC", "bg") or attr("Normal", "bg")
  local fg = attr("WinBar", "fg") or attr("StatusLine", "fg")
  -- The context meter is a raised pill, distinct from the surrounding bar.
  -- Keep its semantic foregrounds while recomputing the surface per colorscheme.
  for _, gauge in ipairs({
    { "GaugeEmpty", "NonText" },
    { "GaugeLabel", "Keyword" },
    { "GaugeLow", "DiagnosticOk" },
    { "GaugeMid", "DiagnosticWarn" },
    { "GaugeHigh", "DiagnosticError" },
  }) do
    vim.api.nvim_set_hl(0, "Yap" .. gauge[1], {
      fg = gauge[1] == "GaugeLabel" and attr("YapModel", "fg") or attr("Yap" .. gauge[1], "fg") or attr(gauge[2], "fg"),
      bg = bg,
    })
  end
  -- Recompute theme-owned surfaces on ColorScheme: caps use the bar's
  -- background, while padding and both counts share one opaque pill.
  vim.api.nvim_set_hl(0, "YapIslandCap", { fg = bg, bg = bar_bg })
  vim.api.nvim_set_hl(0, "YapIslandCapNC", { fg = bg, bg = inactive_bg })
  vim.api.nvim_set_hl(0, "YapIsland", { fg = fg, bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandUprightCount", { fg = attr("YapModel", "fg") or fg, bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandBusy", { fg = attr("YapBusy", "fg"), bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandNeeds", { fg = attr("YapNeeds", "fg"), bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandError", { fg = attr("YapError", "fg"), bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandIdle", { fg = attr("YapIdle", "fg") or fg, bg = bg })
  -- Winbar text styles are aliases so theme colors and other attributes
  -- stay intact while the session title/model are italic and right-side
  -- items explicitly reset italics from linked theme groups.
  local function styled_hl(name, source, italic)
    local attrs = vim.api.nvim_get_hl(0, { name = source, link = false })
    attrs.italic = italic
    vim.api.nvim_set_hl(0, name, attrs)
  end
  for _, group in ipairs({ "Model", "Description" }) do
    styled_hl("YapCursive" .. group, "Yap" .. group, true)
  end
  local model_attrs = vim.api.nvim_get_hl(0, { name = "YapCursiveModel", link = false })
  model_attrs.bg = bg
  vim.api.nvim_set_hl(0, "YapIslandCursiveModel", model_attrs)
  styled_hl("YapUprightIdle", "YapModel", false)
  for _, group in ipairs({ "Error", "Needs", "GaugeEmpty", "GaugeLabel", "GaugeLow", "GaugeMid", "GaugeHigh" }) do
    styled_hl("YapUpright" .. group, "Yap" .. group, false)
  end
  for _, group in ipairs({ "GaugeEmpty", "GaugeLabel", "GaugeLow", "GaugeMid", "GaugeHigh" }) do
    styled_hl("YapIslandUpright" .. group, "Yap" .. group, false)
  end
end

define_winbar_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("YapWinbarHl", { clear = true }),
  callback = define_winbar_hl,
})

return M
