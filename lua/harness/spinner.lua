-- Busy beacon animation, extracted from the winbar: the mood-ring faces, the
-- plain-unicode fallback glyphs and the Ember hue tween that tints them. The
-- beacon randomly loops through the existing emotion groups on each tick; the
-- hue tween is independent of the face, so it keeps cycling amber → coral →
-- rose the whole time a turn runs.

local M = {}

local state = require("harness.state")
local running = state.running

-- Local LCG so the shimmer never reseeds the global math.random other
-- plugins rely on; seeded from the monotonic clock at load.
local rng_state = math.floor(vim.uv.hrtime() % 2 ^ 31) + 1
local function pick(t)
  rng_state = (rng_state * 1664525 + 1013904223) % 2 ^ 32
  return t[rng_state % #t + 1]
end

-- Mood ring: solid single-cell Font Awesome faces grouped by emotion, so the
-- Ember tint still applies (the hollow smile/frown/meh triad is deliberately
-- omitted). The beacon picks a random group, then a random face from it.
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

M.groups = NF_MOOD_RING -- exported for tests: the emotion pools themselves
M.spinner_frames = {} -- exported for tests: every face the beacon can show
for _, b in ipairs(NF_MOOD_RING) do
  for _, g in ipairs(b.faces) do
    M.spinner_frames[#M.spinner_frames + 1] = g
  end
end

local spinner_timer = nil
local spin_tick = 0
local glyph_cache = { tick = -1, glyph = nil, plain = nil }

-- Randomly loop through the emotion groups: each tick picks a fresh group and
-- a random face from it. Cached per tick so a redraw or an elapsed-tool-time
-- change cannot alter the face between timer fires.
function M.glyph()
  if glyph_cache.tick ~= spin_tick then
    glyph_cache = {
      tick = spin_tick,
      glyph = pick(pick(NF_MOOD_RING).faces),
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
