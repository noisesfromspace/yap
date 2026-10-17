-- Busy beacon animation, extracted from the winbar: the status glyphs, the
-- plain-unicode fallback glyphs and the Ember hue tween that tints them. The
-- beacon picks a random glyph each tick from a single uniform set — every
-- glyph renders at the same cell size and the same outline weight, so there is
-- no size jumping. The hue tween is independent of the glyph, so it keeps
-- cycling amber → coral → rose the whole time a turn runs.

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

-- Uniform spinner set: Shapes & status glyphs that all render at the same
-- full cell size (≈1.00×1.00 em) with the same outline weight, so random
-- picks never jump between sizes.
local function nf(cp)
  return vim.fn.nr2char(cp)
end
local NF_SPINNER = {
  -- Font Awesome
  nf(0xF13D), -- anchor
  nf(0xF069), -- asterisk
  nf(0xF0E7), -- bolt
  nf(0xF14E), -- compass
  nf(0xF05B), -- crosshairs
  nf(0xF219), -- gem
  nf(0xF067), -- plus
  nf(0xF2DC), -- snowflake
  nf(0xF00D), -- xmark
  -- Material Design
  nf(0xF0031), -- anchor
  nf(0xF06C4), -- asterisk
  nf(0xF05DD), -- bullseye
  nf(0xF012C), -- check
  nf(0xF0156), -- close
  nf(0xF01A3), -- crosshairs
  nf(0xF0347), -- magnet
  nf(0xF0415), -- plus
  nf(0xF0717), -- snowflake
  nf(0xF04CE), -- star
  nf(0xF04FE), -- target
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
local spin_tick = 0
local glyph_cache = { tick = -1, glyph = nil, plain = nil }

-- Random glyph per tick, from a single uniform set. Cached per tick so a
-- redraw or an elapsed-tool-time change cannot alter the glyph between timer
-- fires.
function M.glyph()
  if glyph_cache.tick ~= spin_tick then
    glyph_cache = {
      tick = spin_tick,
      glyph = pick(NF_SPINNER),
      plain = pick(PLAIN_SPINNER_FRAMES),
    }
  end
  return glyph_cache.glyph
end

function M.plain_glyph()
  M.glyph() -- fill the cache on this tick
  return glyph_cache.plain
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
  glyph_cache.tick = -1
  spinner_timer = vim.uv.new_timer()
  spinner_timer:start(
    0,
    180,
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
