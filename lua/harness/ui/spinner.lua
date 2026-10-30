-- Busy beacon animation: uniform circle glyphs, a short arrival and
-- completion hold, and an independent amber → coral → rose hue tween.
-- A long tool call slows the face changes without slowing the color.

local M = {}

local state = require("harness.state")
local running = state.running

-- Local LCG so the face and plain-fallback picks never reseed the global
-- math.random other plugins rely on; seeded from the monotonic clock at load.
local rng_state = math.floor(vim.uv.hrtime() % 2 ^ 31) + 1
local function pick(t)
  rng_state = (rng_state * 1664525 + 1013904223) % 2 ^ 32
  return t[rng_state % #t + 1]
end

-- Uniform spinner set: 40 Material Design circle glyphs that all render at
-- the same size (measured 1.00×1.00 em) and the same filled weight, so random
-- picks never jump between sizes.
local function nf(cp)
  return vim.fn.nr2char(cp)
end
local NF_SPINNER = {
  nf(0xF0765), -- circle
  nf(0xF05E0), -- check-circle
  nf(0xF0159), -- close-circle
  nf(0xF0376), -- minus-circle
  nf(0xF0417), -- plus-circle
  nf(0xF040C), -- play-circle
  nf(0xF03E5), -- pause-circle
  nf(0xF0666), -- stop-circle
  nf(0xF0EC2), -- record-circle
  nf(0xF0661), -- skip-next-circle
  nf(0xF0028), -- alert-circle
  nf(0xF02D7), -- help-circle
  nf(0xF07C3), -- dots-horizontal-circle
  nf(0xF07C4), -- dots-vertical-circle
  nf(0xF04CF), -- star-circle
  nf(0xF0971), -- heart-circle
  nf(0xF1807), -- fire-circle
  nf(0xF1806), -- water-circle
  nf(0xF1905), -- leaf-circle
  nf(0xF0820), -- lightning-bolt-circle
  nf(0xF1378), -- sync-circle
  nf(0xF1377), -- refresh-circle
  nf(0xF0954), -- clock
  nf(0xF0DF8), -- send-circle
  nf(0xF1464), -- download-circle
  nf(0xF0B2C), -- chevron-up-circle
  nf(0xF0B26), -- chevron-down-circle
  nf(0xF0CE1), -- arrow-up-circle
  nf(0xF0CDB), -- arrow-down-circle
  nf(0xF0B94), -- eye-circle
  nf(0xF0A8C), -- account-supervisor-circle
  nf(0xF0C2E), -- alpha-w-circle
  nf(0xF1853), -- circle-opacity
  nf(0xF02B1), -- google-circles-communities
  nf(0xF0E25), -- comma-circle
  nf(0xF0197), -- contrast-circle
  nf(0xF1421), -- incognito-circle
  nf(0xF1A04), -- percent-circle
  nf(0xF185D), -- radioactive-circle
  nf(0xF0FE1), -- swap-horizontal-circle
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

function M.color()
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

M.spinner_frames = NF_SPINNER -- exported for tests: every glyph the beacon can show

local spinner_timer = nil
local glyph_cache = {} -- per-buffer pacing avoids coupling simultaneous sessions
local started = {} -- buf -> arrival timestamp
local settled = {} -- buf -> brief successful-turn check
local settle_id = 0
local ARRIVAL_NS = 500 * 1e6
local SETTLE_MS = 700
local FAST_TICKS, TOOL_TICKS = 3, 7 -- 60 ms timer: 180 / 420 ms

function M.begin(buf)
  started[buf] = vim.uv.hrtime()
  glyph_cache[buf] = nil
  settled[buf] = nil -- a queued follow-up replaces the old turn's check
end

function M.finish(buf)
  started[buf] = nil
  settle_id = settle_id + 1
  local id = settle_id
  settled[buf] = { glyph = nf(0xF05E0), color = M.color(), id = id }
  vim.api.nvim_set_hl(0, "YapBusySettle", { fg = settled[buf].color })
  vim.defer_fn(function()
    if settled[buf] and settled[buf].id == id then
      settled[buf] = nil
      vim.cmd.redrawstatus()
    end
  end, SETTLE_MS)
  vim.cmd.redrawstatus()
end

function M.cancel(buf)
  started[buf] = nil
  glyph_cache[buf] = nil
  settled[buf] = nil
end

function M.settle(buf)
  return settled[buf]
end
local spin_tick = 0

-- Random glyph per beat, cached per buffer so redraws cannot change the face.
-- The hue continues independently even while a long tool slows the beat.
function M.glyph(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if started[buf] and vim.uv.hrtime() - started[buf] < ARRIVAL_NS then
    return nf(0xF0765)
  end
  local l = state.live[buf]
  local interval = l and l.ms and l.ms >= 2000 and TOOL_TICKS or FAST_TICKS
  local cache = glyph_cache[buf]
  if cache and cache.interval ~= interval then
    cache.tick = spin_tick -- start the new beat from the current face
    cache.interval = interval
  end
  if not cache or spin_tick - cache.tick >= interval then
    cache = { tick = spin_tick, interval = interval, glyph = pick(NF_SPINNER), plain = pick(PLAIN_SPINNER_FRAMES) }
    glyph_cache[buf] = cache
  end
  return cache.glyph
end

function M.plain_glyph(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if started[buf] and vim.uv.hrtime() - started[buf] < ARRIVAL_NS then
    return "※"
  end
  M.glyph(buf)
  return glyph_cache[buf].plain
end

function M.stop_if_idle()
  if spinner_timer and not next(running) then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
end

function M.start()
  if spinner_timer then
    return
  end
  glyph_cache = {}
  spinner_timer = vim.uv.new_timer()
  spinner_timer:start(
    0,
    60,
    vim.schedule_wrap(function()
      spin_tick = spin_tick + 1
      local c = M.color()
      vim.api.nvim_set_hl(0, "YapBusySpin", { fg = c })
      vim.api.nvim_set_hl(0, "YapBusyText", { fg = c, italic = true })
      vim.cmd.redrawstatus() -- re-evaluates the winbar expression
      M.stop_if_idle()
    end)
  )
end

return M
