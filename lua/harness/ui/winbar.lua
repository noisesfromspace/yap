-- Winbar rendering: state, other sessions, title, centered identity and usage.

local M = {}

local state = require("harness.state")
local util = require("harness.util")
local config = require("harness.config")
local frontmatter = require("harness.model.frontmatter")
local spinner = require("harness.ui.spinner")
local view = require("harness.ui.view")
local picker = require("harness.ui.picker")
local session = require("harness.session")

local running = state.running
local live = state.live
local errors = state.errors
local stopped = state.stopped
local awaiting = state.awaiting
local steer = state.steer
local model_switch = state.model_switch
local clear_queued = state.clear_queued
local sessions = state.sessions
local pending_approvals = state.pending_approvals

-- Context is a percentage (`ctx 78%`), not a meter. The cache read-hit rate
-- earns a column only while it is unusually low.
local CACHE_WARN_PCT = 40

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
-- not conversation state (R-buffer-only-state) — same drift tradeoff as yap_usage.

-- Data of the last completed turn per buffer (the binary's `turn_end`
-- event), handed to the User YapTurnDone autocmd. Ephemeral.

-- Other yap sessions (every buffer in `state.sessions` except the current
-- one, with subagents folded into their parent) classified into the five
-- picker states. Iterating a tiny module map, not a full buffer scan, keeps
-- the winbar cheap on every redraw; stale entries are skipped via the
-- validity check.
-- A queued message: the session's scratch has an armed `# @queue`, sent when
-- the running turn ends. Reading the scratch flag keeps one source of truth
-- with the scratch's own "scheduled" label.
local function queued(buf)
  local scratch = vim.b[buf].yap_scratch
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    return false
  end
  return vim.b[scratch].yap_queue_armed and true or false
end

local function other_session_counts(buf)
  local counts = { running = 0, waiting = 0, stopped = 0, error = 0, idle = 0, approval = 0 }
  for b in pairs(sessions) do
    if
      b ~= buf
      and vim.api.nvim_buf_is_valid(b)
      and vim.b[b].yap
      and not (vim.b[b].yap_subagent_parent or picker.agent(nil, b))
    then
      if pending_approvals[b] then
        counts.approval = counts.approval + 1
      else
        local s = picker.state(b)
        if s == "running" then
          counts.running = counts.running + 1
        elseif s == "error" then
          counts.error = counts.error + 1
        elseif s == "stopped" then
          counts.stopped = counts.stopped + 1
        elseif s == "waiting" then
          counts.waiting = counts.waiting + 1
        else
          counts.idle = counts.idle + 1
        end
      end
    end
  end
  return counts
end

-- Seed the awaiting hint for a reopened session from its content (R-buffer-only-state):
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

--- On reopen, restore the error signal only when its marker directly
--- precedes the trailing user prompt. Older error markers remain historical.
function M.seed_error(buf)
  local parsed = require("harness.model.structure").parse(buf)
  local last = parsed.headings[#parsed.headings]
  if not last or last.role ~= "user" then
    return
  end
  local previous = parsed.headings[#parsed.headings - 1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = #parsed.regions, 1, -1 do
    local r = parsed.regions[i]
    if r.finish and r.finish < last.line then
      if r.kind == "error" and (not previous or r.start > previous.line) then
        local body = {}
        for j = r.start + 1, r.finish - 1 do
          body[#body + 1] = lines[j]
        end
        state.errors[buf] = table.concat(body, "\n")
      end
      return
    end
  end
end

--- The un-truncated generated `description`. Cached per changedtick;
--- re-reading and re-parsing frontmatter on every redraw is wasted work.
local title_cache = {} -- buf -> { tick, full }

local function full_description(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = title_cache[buf]
  if c and c.tick == tick then
    return c.full
  end
  local full
  local e = frontmatter.end_line(buf)
  if e then
    local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
    if fm and fm.description ~= "" then
      full = fm.description
    end
  end
  title_cache[buf] = { tick = tick, full = full }
  return full
end

--- The un-truncated session title: a renamed transcript's filename (the
--- session's permanent title), else the generated description. The filename
--- is read every call, so a `:file` rename shows up without a buffer change.
local function full_title(buf)
  return session.file_title(session.display_path(buf)) or full_description(buf)
end

--- The session title for the winbar, truncated to `max` display columns so
--- a long phrase cannot crowd out the right-hand usage/state chips. The
--- description is cached (see full_description); only the cheap width
--- truncation and filename lookup run per call.
local function winbar_title(buf, max)
  local d = full_title(buf)
  return d and view.truncate_display(d, max or 40) or nil
end

-- Layout: state, other-session rollup and title on the left; a centered
-- model island (session label when inactive); usage, cache and context on
-- the right. When narrow, cache yields before context.
local function render_winbar(buf)
  local provider, model = config.current_combo(buf)
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
    upright = upright and s.upright ~= false
    local text
    if s.group == "IslandCap" then
      text = winbar_hl(s.text, inactive and "IslandCapNC" or "IslandCap")
    else
      local style = s.cursive and "Cursive" or (upright and "Upright" or nil)
      if s.island then
        text = island_hl(s.text, s.group, style)
      else
        text = winbar_hl(s.text, (style or "") .. (s.group or "Idle"))
      end
    end
    return text
  end
  local function width_of(segs)
    local n = 0
    for _, s in ipairs(segs) do
      n = n + vim.fn.strdisplaywidth(s.text)
    end
    return n
  end

  local rollup_counts = not inactive and other_session_counts(buf) or nil

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
    local state_icons = {}
    local busy = running and running[buf]
    if busy and stopped[buf] then
      -- The first stop is still unwinding. Keep the spinner visible, but
      -- distinguish cancellation from ordinary generation (even if an
      -- approval was parked when the user pressed stop).
      if not inactive then
        state_icons[#state_icons + 1] = seg(icons.stopped, "Needs")
        local glyph = require("harness").config.nerd_font and spinner.glyph(buf) or spinner.plain_glyph(buf)
        state_icons[#state_icons + 1] = seg(glyph, "BusySpin")
      else
        state_icons[#state_icons + 1] = seg(icons.stopped, "Needs")
      end
    elseif pending_approvals[buf] then
      -- A parked approval outranks the busy spinner: the session needs a
      -- decision, not a "streaming" signal, and must stay visible from an
      -- inactive window too.
      state_icons[#state_icons + 1] = seg(icons.approval, "Approval")
    elseif not inactive and busy then
      -- A queued message, a pending clear, a pending steer and a pending
      -- model switch advertise themselves immediately left of the running
      -- beacon, so all stay visible in the gutter while streaming (the
      -- queue and clear run at turn completion, then the model switch and
      -- steer are applied at the next boundary).
      if queued(buf) then
        state_icons[#state_icons + 1] = seg(icons.queue, "Needs")
      end
      if clear_queued[buf] then
        state_icons[#state_icons + 1] = seg(icons.clear, "Needs")
      end
      if steer[buf] then
        state_icons[#state_icons + 1] = seg(icons.steer, "Needs")
      end
      if model_switch[buf] then
        state_icons[#state_icons + 1] = seg(icons.model_switch, "Needs")
      end
      local glyph = require("harness").config.nerd_font and spinner.glyph(buf) or spinner.plain_glyph(buf)
      state_icons[#state_icons + 1] = seg(glyph, "BusySpin")
    elseif inactive and busy then
      -- A generating session drops its animated beacon when inactive, but a
      -- static running glyph keeps the window from looking dead, and any
      -- queued message, pending clear, steer or model switch still
      -- advertises itself left of it.
      if queued(buf) then
        state_icons[#state_icons + 1] = seg(icons.queue, "Needs")
      end
      if clear_queued[buf] then
        state_icons[#state_icons + 1] = seg(icons.clear, "Needs")
      end
      if steer[buf] then
        state_icons[#state_icons + 1] = seg(icons.steer, "Needs")
      end
      if model_switch[buf] then
        state_icons[#state_icons + 1] = seg(icons.model_switch, "Needs")
      end
      state_icons[#state_icons + 1] = seg(icons.running, "Busy")
    elseif not busy then
      if errors[buf] then
        state_icons[#state_icons + 1] = seg(icons.error, "Error")
      elseif stopped[buf] then
        state_icons[#state_icons + 1] = seg(icons.stopped, "Needs")
      elseif queued(buf) then
        state_icons[#state_icons + 1] = seg(icons.queue, "Needs")
      elseif steer[buf] then
        state_icons[#state_icons + 1] = seg(icons.steer, "Needs")
      elseif awaiting[buf] and picker.agent(nil, buf) then
        state_icons[#state_icons + 1] = seg(icons.done, "Idle")
      elseif awaiting[buf] then
        state_icons[#state_icons + 1] = seg(icons.waiting, "Needs")
      else
        state_icons[#state_icons + 1] = seg(icons.idle, "Idle")
      end
    end

    local icon_width = width_of(state_icons)
    if gutter > 0 and icon_width <= gutter then
      local lead = math.floor((gutter - icon_width) / 2)
      left[#left + 1] = seg(string.rep(" ", lead), "Idle")
      for _, s in ipairs(state_icons) do
        left[#left + 1] = s
      end
      local trail = gutter - lead - icon_width
      if trail > 0 then
        left[#left + 1] = seg(string.rep(" ", trail), "Idle")
      end
    elseif icon_width > 0 then
      -- No gutter (line numbers off), or the icon stack (pending actions plus
      -- the beacon) is wider than the gutter: the icons become the leftmost
      -- text item instead of overflowing the gutter and shifting the title.
      add_item(state_icons)
    end

    -- Tool text belongs to the text region, ahead of the rollup. A queued
    -- message, pending steer or stopping icon joins the leftmost state icon
    -- (see above).
    if not inactive and busy and not stopped[buf] then
      local l = live and live[buf]
      if l and l.ms and l.ms >= 2000 then
        local label = l.name .. " " .. math.floor(l.ms / 1000) .. "s"
        add_item({ seg(label, "BusyText") })
      end
    end

    -- The title anchors the left text edge. It sits before the rollup so the
    -- island's changing width (a subagent's parent flipping running ->
    -- waiting, a count crossing a digit boundary) can never shift the title
    -- or the tool label; the island grows into the gap toward the center.
    local title = not inactive and winbar_title(buf, desc_max) or nil
    if title then
      add_item({ seg(title, "Description", false, true) })
    end

    -- The rollup island totals every OTHER session by state. It is the
    -- active session's dashboard, not this window's own signal, so an
    -- inactive window hides it entirely: the only thing a background
    -- session is allowed to advertise is its own leftmost state icon.
    if not inactive then
      local counts = rollup_counts
      local order = {
        { icons.approval, counts.approval, "Approval" },
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
            rollup[#rollup + 1] = seg(" │ ", "Sep", true)
          end
          rollup[#rollup + 1] = seg(chip[1] .. chip[2], chip[3], true)
          first = false
        end
      end
      if not first then
        rollup[#rollup + 1] = seg(" ", nil, true)
        rollup[#rollup + 1] = seg(icons.cap_r, "IslandCap")
        add_item(rollup)
      end
    end

    if has_item then
      left[#left + 1] = seg(" ", "Idle")
    end
    return left
  end

  -- Turn-wide cache read-hit rate from cumulative usage: cache_read divided by
  -- total turn input (prompt + cache_read + cache_write). Writes are not hits.
  -- Hide only when cache fields are absent or total input is zero.
  local function cache_percent(t)
    if not t then
      return nil
    end
    if t.cache_read == nil and t.cache_write == nil then
      return nil -- provider reported no cache status: hide (never fake 0%)
    end
    local prompt = tonumber(t.prompt) or 0
    local cache_read = tonumber(t.cache_read) or 0
    local cache_write = tonumber(t.cache_write) or 0
    local total_input = prompt + cache_read + cache_write
    if total_input <= 0 then
      return nil
    end
    return math.min(cache_read / total_input * 100, 100)
  end

  -- Cache is a warning, not a permanent chip: `⧉ NN%` in the warning color
  -- only while the read-hit rate is unusually low. A healthy cache is
  -- invisible; absent cache data is never faked as 0%.
  local function cache_parts()
    local pct = cache_percent(state.live_usage[buf] or state.last_turn[buf])
    if not pct or pct >= CACHE_WARN_PCT then
      return nil
    end
    local num = pct < 1 and string.format("%.1f%%", pct) or string.format("%.0f%%", pct)
    return { { icons.cache .. " ", "Count" }, { num, "Needs" } }
  end

  -- Context as a percentage, not a meter: `ctx 78%`. The number carries the
  -- reading, the label carries it without color. Green below 70%, amber
  -- 70-89%, red 90%+.
  local function context_segment()
    local t = state.live_usage[buf] or state.last_turn[buf]
    local ctx = t and tonumber(t.context_window) or nil
    local prompt = t and tonumber(t.context_prompt or t.prompt) or nil
    if not ctx or ctx <= 0 or not prompt or prompt <= 0 then
      return nil
    end

    local pct = math.min(prompt / ctx * 100, 100)
    local shown = math.max(0, math.floor(pct + 0.5))
    local color = pct >= 90 and "GaugeHigh" or (pct >= 70 and "GaugeMid" or "GaugeLow")
    return { { " ", "GaugeEmpty", true }, { "ctx " .. shown .. "%", color, true }, { " ", "GaugeEmpty", true } }
  end

  -- Usage counters and the context reading stay right-aligned.
  -- As the bar narrows, costs, tokens, cache and then the reading drop; the
  -- model name in the center outlives the right-side metrics.
  local function usage_segment(mode, show_context, show_cache)
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

    local context = show_context and context_segment() or nil
    local cache = show_cache and cache_parts() or nil
    if #chips == 0 and not context and not cache then
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
    if cache then
      pill(cache)
    end
    if context then
      pill(context)
    end
    segs[#segs + 1] = seg(" ", "Idle")
    return segs
  end

  -- Active windows center the model; inactive windows center the session label.
  local function center_segments()
    local text = provider .. "/" .. model
    if inactive then
      local label = session.label(vim.b[buf].yap_path, full_title(buf))
      text = view.truncate_display(label, 40)
    end
    return {
      seg(" ", "Idle"),
      seg("", "IslandCap"),
      seg(" ", "Count", true),
      seg(text, "Model", true, true),
      seg(" ", "Count", true),
      seg("", "IslandCap"),
    }
  end

  -- The state icon now lives on the left (see left_segments); the right
  -- side keeps only the usage counters and the context meter.

  local function render(left, center, usage, left_width, right_width, centered)
    local parts = {}
    for _, s in ipairs(left) do
      parts[#parts + 1] = render_seg(s)
    end
    -- Balance the side clusters so the island lands at the true midpoint.
    if centered and left_width < right_width then
      parts[#parts + 1] = string.rep(" ", right_width - left_width)
    end
    parts[#parts + 1] = "%="
    if center then
      for _, s in ipairs(center) do
        parts[#parts + 1] = render_seg(s, true)
      end
      parts[#parts + 1] = "%="
      if centered and right_width < left_width then
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
  -- would collide with it, then degrade the right side.
  -- Layout negotiation tries several widths synchronously. Only title limit,
  -- model visibility and usage mode change between attempts; reuse segments.
  local left_cache, center_cache, usage_cache = {}, {}, {}
  local function cached(cache, key, build)
    if cache[key] == nil then
      cache[key] = build() or false
    end
    return cache[key] or nil
  end
  local desc_max, mode, show_model, show_cache, show_context = 40, "full", true, true, true
  while true do
    local left = cached(left_cache, desc_max, function()
      return left_segments(desc_max)
    end)
    local center = show_model and cached(center_cache, true, center_segments) or nil
    local usage = not inactive and cached(usage_cache, mode .. ":" .. tostring(show_cache) .. ":" .. tostring(show_context), function()
      return usage_segment(mode, show_context, show_cache)
    end) or nil
    local left_width = width_of(left)
    local right_width = usage and width_of(usage) or 0
    local center_width = center and width_of(center) or 0
    local total = left_width + center_width + right_width
    -- Centering applies only while the model or inactive label is shown.
    local fits = total <= width
    if center and show_model then
      fits = fits
        and left_width <= math.floor((width - center_width) / 2)
        and right_width <= math.floor((width - center_width) / 2)
    end
    if fits then
      return render(left, center, usage, left_width, right_width, show_model)
    end
    -- Costs, token counts, cache, then context yield before the identity.
    if mode == "full" then
      mode = "compact"
    elseif mode == "compact" then
      mode = "prices"
    elseif show_cache then
      show_cache = false
    elseif show_context then
      show_context = false
    elseif show_model then
      show_model = false
    elseif desc_max > 15 then
      desc_max = desc_max - 5
    else
      return render(left, nil, usage, left_width, right_width, false) -- smallest layout; let it clip
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

--- Drop a buffer's cached title (BufWipeout). The changedtick check already
--- invalidates on buffer-number reuse; this releases the entry sooner.
function M.clear_desc(buf)
  title_cache[buf] = nil
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

local function define_winbar_hl()
  local links = {
    Model = "Keyword",
    Description = "Title",
    Busy = "DiagnosticOk",
    Done = "DiagnosticOk",
    Idle = "Comment",
    Error = "DiagnosticError",
    Approval = "DiagnosticError",
    Needs = "DiagnosticWarn",
    GaugeEmpty = "NonText",
    GaugeLow = "DiagnosticOk",
    GaugeMid = "DiagnosticWarn",
    GaugeHigh = "DiagnosticError",
  }
  for name, link in pairs(links) do
    view.link("Yap" .. name, link)
  end
  -- The busy beacon and its tool text share one live-updated color, so the
  -- animated face and "bash 12s" tint in lockstep; the tick re-tints both.
  local busy = spinner.color()
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
    { "GaugeLow", "DiagnosticOk" },
    { "GaugeMid", "DiagnosticWarn" },
    { "GaugeHigh", "DiagnosticError" },
  }) do
    vim.api.nvim_set_hl(0, "Yap" .. gauge[1], {
      fg = attr("Yap" .. gauge[1], "fg") or attr(gauge[2], "fg"),
      bg = bg,
    })
  end
  -- Recompute theme-owned surfaces on ColorScheme: caps use the bar's
  -- background, while padding and both counts share one opaque pill.
  vim.api.nvim_set_hl(0, "YapIslandCap", { fg = bg, bg = bar_bg })
  vim.api.nvim_set_hl(0, "YapIslandCapNC", { fg = bg, bg = inactive_bg })
  vim.api.nvim_set_hl(0, "YapIsland", { fg = fg, bg = bg })
  -- The rollup chip divider recedes behind the semantic chip colors: the
  -- same raised surface, but a quiet Comment/NonText foreground.
  vim.api.nvim_set_hl(0, "YapIslandSep", { fg = attr("Comment", "fg") or attr("NonText", "fg") or fg, bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandUprightCount", { fg = attr("YapModel", "fg") or fg, bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandBusy", { fg = attr("YapBusy", "fg"), bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandNeeds", { fg = attr("YapNeeds", "fg"), bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandUprightNeeds", { fg = attr("YapNeeds", "fg"), bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandError", { fg = attr("YapError", "fg"), bg = bg })
  vim.api.nvim_set_hl(0, "YapIslandApproval", { fg = attr("YapApproval", "fg"), bg = bg })
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
  for _, group in ipairs({ "Error", "Needs", "GaugeEmpty", "GaugeLow", "GaugeMid", "GaugeHigh" }) do
    styled_hl("YapUpright" .. group, "Yap" .. group, false)
  end
  for _, group in ipairs({ "GaugeEmpty", "GaugeLow", "GaugeMid", "GaugeHigh" }) do
    styled_hl("YapIslandUpright" .. group, "Yap" .. group, false)
  end
end

define_winbar_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("YapWinbarHl", { clear = true }),
  callback = define_winbar_hl,
})

return M
