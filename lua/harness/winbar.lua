-- Winbar rendering — the self-evaluating `%!` statusline at the top of a
-- yap session buffer: busy beacon (or the buffer's own state icon), global
-- rollup island, session description, provider/model island and usage/cost
-- chips. Usage/cost chips remain on the right. The spinner only redraws the
-- display while the turn is running; the audit poll owns live tool output.

local M = {}

local state = require("harness.state")
local util = require("harness.util")
local config = require("harness.config")
local frontmatter = require("harness.frontmatter")
local spinner = require("harness.spinner")

local running = state.running
local live = state.live
local errors = state.errors
local stopped = state.stopped
local awaiting = state.awaiting
local steer = state.steer
local sessions = state.sessions
local pending_approvals = state.pending_approvals

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
-- not conversation state (R-buffer-only-state) — same drift tradeoff as yap_usage.

-- Data of the last completed turn per buffer (the binary's `turn_end`
-- event), handed to the User YapTurnDone autocmd. Ephemeral.

-- Other yap sessions (every buffer in `state.sessions` except the current
-- one, with subagents folded into their parent) classified into the five
-- picker states. Iterating a tiny module map, not a full buffer scan, keeps
-- the winbar cheap on every redraw; stale entries are skipped via the
-- validity check.
local function other_session_counts(buf)
  local counts = { running = 0, waiting = 0, stopped = 0, error = 0, idle = 0, approval = 0 }
  for b in pairs(sessions) do
    if
      b ~= buf
      and vim.api.nvim_buf_is_valid(b)
      and vim.b[b].yap
      and not (vim.b[b].yap_subagent_parent or vim.b[b].yap_agent)
    then
      if pending_approvals[b] then
        counts.approval = counts.approval + 1
      elseif running[b] then
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

--- The un-truncated frontmatter title for a buffer: `title` when set, else
--- the generated `description`. Cached per changedtick; the winbar
--- re-evaluates on every screen draw and the title only changes when the
--- buffer is edited, so re-reading and re-parsing the frontmatter each
--- redraw is wasted work.
local title_cache = {} -- buf -> { tick, full }

local function full_title(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = title_cache[buf]
  if c and c.tick == tick then
    return c.full
  end
  local full
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 30, false)
  if lines[1] and lines[1]:match("^%-%-%-%s*$") then
    local fm = frontmatter.parse(lines)
    if fm and fm.title and fm.title ~= "" then
      full = fm.title
    elseif fm and fm.description and fm.description ~= "" then
      full = fm.description
    end
  end
  title_cache[buf] = { tick = tick, full = full }
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

--- The session title for the winbar, truncated to `max` display columns so
--- a long phrase cannot crowd out the right-hand usage/state chips. The
--- full title is cached (see full_title); only the cheap width truncation
--- runs per call.
local function winbar_title(buf, max)
  local d = full_title(buf)
  return d and truncate_display(d, max or 40) or nil
end

-- Layout: a spinner beacon on the left (this buffer streaming, plus the
-- running tool's name once it has run 2s) or this buffer's state icon
-- (stopped/error/waiting/idle), then the global-session rollup island and
-- the description on the left; a centered provider/model island with the
-- three-stop fold view switch to its right (in the active bar only — an
-- inactive bar keeps the switch on the left); usage counters and context
-- meter on the right. As the window narrows the center island drops, then
-- the switch; usage counters and context meter retain their existing width
-- priorities.
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

  local function seg(text, group, island, cursive, click)
    return { text = text, group = group, island = island, cursive = cursive, click = click }
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
    return s.click and ("%" .. s.click .. "@v:lua.YapFoldViewClick@" .. text .. "%T") or text
  end
  local function width_of(segs)
    local n = 0
    for _, s in ipairs(segs) do
      n = n + vim.fn.strdisplaywidth(s.text)
    end
    return n
  end

  -- The three-stop fold view switch. Rendered with its own groups (not the
  -- upright style the center section applies), so it looks identical whether
  -- it sits in the left cluster (inactive bar) or beside the model island
  -- (active bar).
  local function fold_switch_segs()
    local selected = require("harness.fold").level(win)
    local stops = {}
    for level = 1, 3 do
      local s = seg(" " .. level .. " ", level == selected and "ViewActive" or "ViewInactive", false, false, level)
      s.upright = false
      stops[#stops + 1] = s
    end
    return stops
  end

  -- Mandatory left cluster (never dropped; the description shrinks). Build
  -- logical items first, with breathing room between sections rather than
  -- repeated dividers. The rollup uses lualine's bubbles-style rounded caps.
  local function left_segments(desc_max, show_switch)
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
    local busy = running and running[buf]
    if pending_approvals[buf] then
      -- A parked approval outranks the busy spinner: the session needs a
      -- decision, not a "streaming" signal, and must stay visible from an
      -- inactive window too.
      icon, icon_group = icons.approval, "Approval"
    elseif not inactive and busy then
      icon = require("harness").config.nerd_font and spinner.glyph() or spinner.plain_glyph()
      icon_group = "BusySpin"
    elseif not busy then
      if errors[buf] then
        icon, icon_group = icons.error, "Error"
      elseif stopped[buf] then
        icon, icon_group = icons.stopped, "Needs"
      elseif steer[buf] then
        icon, icon_group = icons.steer, "Needs"
      elseif awaiting[buf] and vim.b[buf].yap_agent then
        icon, icon_group = icons.done, "Idle"
      elseif awaiting[buf] then
        icon, icon_group = icons.waiting, "Needs"
      else
        icon, icon_group = icons.idle, "Idle"
      end
    end

    if gutter > 0 then
      local lead = math.floor((gutter - 1) / 2)
      left[#left + 1] = seg(string.rep(" ", lead), "Idle")
      if icon then
        left[#left + 1] = seg(icon, icon_group)
      end
      local trail = gutter - lead - (icon and 1 or 0)
      if trail > 0 then
        left[#left + 1] = seg(string.rep(" ", trail), "Idle")
      end
    elseif icon then
      -- No gutter (e.g. line numbers off): the icon is the leftmost item.
      add_item({ seg(icon, icon_group) })
    end

    -- The fold-view switch lives in the left cluster only for an inactive
    -- bar; the active bar parks it to the right of the centered model island.
    if show_switch then
      add_item(fold_switch_segs())
    end

    -- Tool text belongs to the text region, ahead of the rollup. A pending
    -- steer icon instead joins the model island (see center_segments).
    if not inactive and busy then
      local l = live and live[buf]
      if l and os.time() - l.since >= 2 then
        add_item({ seg(l.name .. " " .. (os.time() - l.since) .. "s", "BusyText") })
      end
    end

    -- The rollup island totals every OTHER session by state. It is the
    -- active session's dashboard, not this window's own signal, so an
    -- inactive window hides it entirely: the only thing a background
    -- session is allowed to advertise is its own leftmost state icon.
    if not inactive then
      local counts = other_session_counts(buf)
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

    local title = not inactive and winbar_title(buf, desc_max) or nil
    if title then
      add_item({ seg(title, "Description", false, true) })
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

  -- The center section holds the model island and, in the active bar, the
  -- fold-view switch to its right. Inactive sessions show their session
  -- identity instead of a model that is only useful while that session is
  -- selected. A pending steer icon sits immediately left of the model; a
  -- matching blank cell on the right keeps the model name on the true
  -- midpoint. The switch is added with a matching blank on the left so the
  -- model name stays centered even though the whole section grows. When the
  -- window is too narrow for the island, it drops alone and leaves the
  -- switch behind (see render_winbar).
  local function center_segments(show_model, switch_in_center)
    local switch_segs = switch_in_center and fold_switch_segs() or nil
    if not show_model and not switch_segs then
      return nil
    end
    local center = {}
    if show_model then
      local text = provider .. "/" .. model
      if inactive then
        local label = require("harness.session").label(vim.b[buf].yap_path, nil, full_title(buf))
        text = truncate_display(label, 40)
      end
      local show_steer = not inactive and steer[buf] ~= nil
      if switch_segs then
        -- Blank left of the island: the switch width plus its two-column gap.
        center[#center + 1] = seg(string.rep(" ", width_of(switch_segs) + 2), "Idle")
      end
      center[#center + 1] = seg(" ", "Idle")
      center[#center + 1] = seg("", "IslandCap")
      center[#center + 1] = seg(" ", "Count", true)
      if show_steer then
        center[#center + 1] = seg(icons.steer, "Needs", true)
        center[#center + 1] = seg(" ", "Count", true)
      end
      center[#center + 1] = seg(text, "Model", true, true)
      center[#center + 1] = seg(" ", "Count", true)
      if show_steer then
        center[#center + 1] = seg("  ", "Count", true)
      end
      center[#center + 1] = seg("", "IslandCap")
    end
    if switch_segs then
      center[#center + 1] = seg(show_model and "  " or " ", "Idle")
      for _, s in ipairs(switch_segs) do
        center[#center + 1] = s
      end
      center[#center + 1] = seg(" ", "Idle")
    end
    return center
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
  local desc_max, mode, show_model, show_switch = 40, "full", true, true
  while true do
    local left = left_segments(desc_max, inactive and show_switch)
    local switch_in_center = not inactive and show_switch
    local center = (show_model or switch_in_center) and center_segments(show_model, switch_in_center) or nil
    local usage = not inactive and usage_segment(mode)
    local left_width = width_of(left)
    local right_width = usage and width_of(usage) or 0
    local center_width = center and width_of(center) or 0
    local total = left_width + center_width + right_width
    -- Only the model island (or an inactive session's label) needs true
    -- centering; a switch alone can sit anywhere it fits. So the centering
    -- constraint applies only while the model is still shown.
    local fits = total <= width
    if center and show_model then
      fits = fits
        and left_width <= math.floor((width - center_width) / 2)
        and right_width <= math.floor((width - center_width) / 2)
    end
    if fits then
      return render(left, center, usage, left_width, right_width)
    end
    if show_model then
      show_model = false
    elseif show_switch then
      show_switch = false
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

--- Select a fold view from the winbar. The click belongs to the window under
--- the mouse, which can differ from the current window in a split.
_G.YapFoldViewClick = function(level, _, button)
  if button ~= "l" or level < 1 or level > 3 then
    return
  end
  local win = vim.fn.getmousepos().winid
  if win == 0 or not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_win_call(win, function()
    require("harness.fold").set_view_level(level)
  end)
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
    ViewActive = "Keyword",
    ViewInactive = "Comment",
    Busy = "DiagnosticOk",
    Done = "DiagnosticOk",
    Idle = "Comment",
    Error = "DiagnosticError",
    Approval = "DiagnosticError",
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
  vim.api.nvim_set_hl(0, "YapViewActive", { fg = attr("YapModel", "fg") or fg, bg = bg, bold = true })
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
