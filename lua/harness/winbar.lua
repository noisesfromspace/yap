-- Winbar rendering — the self-evaluating `%!` statusline at the top of a
-- yap session buffer: busy beacon, global rollup island, session
-- description, provider/model island, usage/cost chips and the right-edge
-- state glyph. Usage/cost chips remain on the right. Also owns the spinner
-- that keeps the bar redrawing while a turn streams; the spinner drains
-- live tool output into the tail buffers through state.drain_tail (set by
-- the send path).

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

-- Irregular, randomly sampled star shapes instead of a rotating arc.
-- The old typographic sparkle pool stays available without a Nerd Font.
local SPINNER_FRAMES = { "󰫢", "󰫥", "󰙴", "󰫣", "󰫤", "󰫊", "󱝁", "󰃠", "󰫉" }
local PLAIN_SPINNER_FRAMES = { "※", "⁕", "⁜", "⁑", "✳", "✦", "✧", "⋆", "⁂" }
local SPINNER_COLORS = { "BusyTeal", "BusyBlue", "BusyViolet" }
M.spinner_frames = SPINNER_FRAMES -- exported for tests: a random shimmer is hard to assert
local spinner_glyph = SPINNER_FRAMES[1]
local plain_spinner_glyph = PLAIN_SPINNER_FRAMES[1]
local spinner_color = SPINNER_COLORS[1]
local spinner_timer = nil

-- Local LCG so the shimmer never reseeds the global math.random other
-- plugins rely on; seeded from the monotonic clock at load.
local rng_state = math.floor(vim.uv.hrtime() % 2 ^ 31) + 1
local function pick(t)
  rng_state = (rng_state * 1664525 + 1013904223) % 2 ^ 32
  return t[rng_state % #t + 1]
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

-- Other yap buffers in `set` (awaiting or running): the count for the
-- global overview/rollup chips. A tiny module map, so no buffer scans on
-- redraw (R10); stale entries are skipped via the validity check.
local function count_others(set, buf)
  local n = 0
  for b in pairs(set) do
    if b ~= buf and vim.api.nvim_buf_is_valid(b) and vim.b[b].yap
      and not (set == awaiting and (vim.b[b].yap_subagent_parent or errors[b] or stopped[b])) then
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
-- description on the left; a centered provider/model island; usage counters
-- and context meter on the right, followed by an error glyph.
-- As the window narrows the center island drops, then costs, then tokens;
-- the error glyph, prices and context meter survive. Past that the bar clips.
local function render_winbar(buf)
  local provider, model = util.current_combo(buf)
  local icons = require("harness").config.icons
  local ok_w, width = pcall(vim.api.nvim_win_get_width, 0)
  if not ok_w or not width or width <= 0 then
    width = 999 -- no window context: render the full bar
  end

  local function seg(text, group, island, cursive)
    return { text = text, group = group, island = island, cursive = cursive }
  end
  local win = tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
  local inactive = win ~= vim.api.nvim_get_current_win()
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
    local left, has_item = {}, false
    local function add_item(item)
      -- One left inset; separators belong to the layout, not the items.
      left[#left + 1] = seg(has_item and "  " or " ", "Idle")
      for _, s in ipairs(item) do
        left[#left + 1] = s
      end
      has_item = true
    end

    local spinner = running and running[buf]
    if spinner then
      local l = live and live[buf]
      local text = require("harness").config.nerd_font and spinner_glyph or plain_spinner_glyph
      local item = { seg(text, spinner_color) }
      if l and os.time() - l.since >= 2 then
        item[#item + 1] = seg(" " .. l.name .. " " .. (os.time() - l.since) .. "s", "BusyText")
      end
      add_item(item)
    elseif awaiting[buf] and not errors[buf] then
      add_item({ seg("", "Done") })
    end

    local running_others_n = count_others(running, buf)
    local others = count_others(awaiting, buf)
    if running_others_n > 0 or others > 0 then
      local rollup = { seg(icons.cap_l, "IslandCap"), seg(" ", nil, true) }
      if running_others_n > 0 then
        rollup[#rollup + 1] = seg(icons.running .. running_others_n, "Busy", true)
      end
      if running_others_n > 0 and others > 0 then
        rollup[#rollup + 1] = seg("  ", nil, true)
      end
      if others > 0 then
        rollup[#rollup + 1] = seg(icons.waiting .. others, "Needs", true)
      end
      rollup[#rollup + 1] = seg(" ", nil, true)
      rollup[#rollup + 1] = seg(icons.cap_r, "IslandCap")
      add_item(rollup)
    end

    local desc = winbar_description(buf, desc_max)
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
        left = { "", "" }, mid = { "", "" }, right = { "", "" },
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
  local function center_segments()
    return {
      seg(" ", "Idle"), seg("", "IslandCap"), seg(" ", "Count", true),
      seg(provider .. "/" .. model, "Model", true, true), seg(" ", "Count", true), seg("", "IslandCap"),
      seg(" ", "Idle"),
    }
  end

  -- Only an error gets a right-edge glyph: idle and "awaiting your reply"
  -- are self-evident from the absence of the left spinner, so they stay
  -- silent. The awaiting state still drives the OTHER-buffer rollup island.
  local function state_segment()
    if errors[buf] then
      return seg(" " .. icons.error .. " error ", "Error")
    end
    if steer[buf] then
      return seg(" " .. icons.steer .. " steer ", "Needs")
    end
    return nil
  end

  local function render(left, center, usage, state, left_width, right_width)
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
    if state then
      parts[#parts + 1] = render_seg(state, true)
    end
    return table.concat(parts, "")
  end

  -- Preserve real centering: drop the middle when either edge cluster
  -- would collide with it, then degrade the right side as before.
  local desc_max, mode, show_mid = 40, "full", true
  while true do
    local left = left_segments(desc_max)
    local center = show_mid and center_segments() or nil
    local usage = usage_segment(mode)
    local state = state_segment()
    local left_width = width_of(left)
    local right_width = (usage and width_of(usage) or 0) + (state and width_of({ state }) or 0)
    local center_width = center and width_of(center) or 0
    local total = left_width + center_width + right_width
    if total <= width and (not center or
        (left_width <= math.floor((width - center_width) / 2)
          and right_width <= math.floor((width - center_width) / 2))) then
      return render(left, center, usage, state, left_width, right_width)
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
      return render(left, nil, usage, state, left_width, right_width) -- smallest layout; let it clip
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

--- The herdr-style rollup for a statusline/tabline: `<waiting icon>N` when
--- N OTHER yap buffers await the user's reply, "" otherwise. The winbar
--- shows the same chip, so this is the reusable segment for global
--- visibility.
function M.overview(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local n = count_others(awaiting, buf)
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
  spinner_timer = vim.uv.new_timer()
  spinner_timer:start(
    0,
    180,
    vim.schedule_wrap(function()
      spinner_glyph = pick(SPINNER_FRAMES)
      plain_spinner_glyph = pick(PLAIN_SPINNER_FRAMES)
      spinner_color = pick(SPINNER_COLORS)
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
    BusyText = "YapCursiveModel",
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
