-- Busy beacon animation, extracted from the winbar: the smiley faces, the
-- plain-unicode fallback glyphs and the Ember hue tween that tints them. The
-- beacon picks a random face but stays in one size tier — the same-size
-- (light) faces first — for as many ticks as the tier has faces, then moves to
-- the bigger (filled) tier even if randomness skipped some. The hue tween is
-- independent of the face, so it keeps cycling amber → coral → rose the whole
-- time a turn runs.

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

-- Size tiers: the light smileys (Font Awesome faces, Material Design outline
-- emoticons, and the lone Codicon + Octicon smileys) all render at one size;
-- the filled Material Design emoticons render noticeably bigger. The beacon
-- picks randomly within a tier, and switches tiers after as many ticks as the
-- tier has faces.
local function nf(cp)
  return vim.fn.nr2char(cp)
end
local NF_SIZE_TIERS = {
  {
    -- Same size: Font Awesome faces (solid + hollow), then Material Design
    -- outline emoticons, then the Codicon and Octicon smileys.
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
      nf(0xF118),
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
      nf(0xEE89),
      nf(0xEE4C),
      nf(0xEE6E),
      nf(0xEE42),
      nf(0xEE6D),
      nf(0xF11A),
      nf(0xEE48),
      nf(0xEE8F),
      nf(0xEE43),
      nf(0xEE1F),
      nf(0xEE7C),
      nf(0xF119),
      nf(0xEE30),
      nf(0xEE7B),
      nf(0xF01F2),
      nf(0xF01F5),
      nf(0xF069C),
      nf(0xF01F3),
      nf(0xF0C79),
      nf(0xF0C73),
      nf(0xF1215),
      nf(0xF0C77),
      nf(0xF01F4),
      nf(0xF0C6A),
      nf(0xF0C6D),
      nf(0xF069B),
      nf(0xF0F4D),
      nf(0xF01F8),
      nf(0xF157D),
      nf(0xF10DF),
      nf(0xF01F6),
      nf(0xF0C75),
      nf(0xEB54),
      nf(0xF4A2),
    },
  },
  {
    -- Bigger: filled Material Design emoticons.
    faces = {
      nf(0xF0C68),
      nf(0xF0C71),
      nf(0xF0C70),
      nf(0xF0C6B),
      nf(0xF0C78),
      nf(0xF0C72),
      nf(0xF1214),
      nf(0xF01F9),
      nf(0xF0C6F),
      nf(0xF0C69),
      nf(0xF0C6C),
      nf(0xF0C6E),
      nf(0xF0F4C),
      nf(0xF0C76),
      nf(0xF157C),
      nf(0xF10DE),
      nf(0xF0C74),
      nf(0xF01F7),
    },
  },
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

M.groups = NF_SIZE_TIERS -- exported for tests: the size tiers themselves
M.spinner_frames = {} -- exported for tests: every face the beacon can show
for _, b in ipairs(NF_SIZE_TIERS) do
  for _, g in ipairs(b.faces) do
    M.spinner_frames[#M.spinner_frames + 1] = g
  end
end

local spinner_timer = nil
local spin_tick = 0
local tier_index = 1 -- current size tier
local tier_ticks = 0 -- ticks spent in the current tier
local glyph_cache = { tick = -1, glyph = nil, plain = nil }

-- Random face per tick, but tiered: each size tier runs for as many ticks as
-- it has faces, then the next tier takes over — even if randomness skipped
-- some faces. Cached per tick so a redraw or an elapsed-tool-time change
-- cannot alter the face between timer fires.
function M.glyph()
  if glyph_cache.tick ~= spin_tick then
    tier_ticks = tier_ticks + 1
    if tier_ticks > #NF_SIZE_TIERS[tier_index].faces then
      tier_index = tier_index % #NF_SIZE_TIERS + 1
      tier_ticks = 1
    end
    glyph_cache = {
      tick = spin_tick,
      glyph = pick(NF_SIZE_TIERS[tier_index].faces),
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
  tier_index = 1 -- each turn restarts in the same-size tier
  tier_ticks = 0
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
