-- The beacon stays in the same-size tier first, picks a random face each tick,
-- and moves to the bigger tier after as many ticks as the tier has faces —
-- even though randomness means some faces may not have shown. A redraw or a
-- tool-time change must never advance the face.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local spinner = require("harness.spinner")
local state = require("harness.state")
local buf = yap.new()
state.running[buf] = {}
state.live[buf] = { name = "bash", since = os.time() - 1000 }

local original_timer = vim.uv.new_timer
local tick
vim.uv.new_timer = function()
  return {
    start = function(_, _, _, callback)
      tick = callback
    end,
    stop = function() end,
    close = function() end,
  }
end
spinner.start()
vim.uv.new_timer = original_timer

local tier_of = {}
for ti, tier in ipairs(spinner.groups) do
  for _, glyph in ipairs(tier.faces) do
    tier_of[glyph] = ti
  end
end
local function face()
  local bar = yap.winbar(buf)
  for _, glyph in ipairs(spinner.spinner_frames) do
    if bar:find(glyph, 1, true) then
      return glyph
    end
  end
  error("missing face: " .. bar)
end

local function tier_len(ti)
  return #spinner.groups[ti].faces
end

local glyph = face()
assert(tier_of[glyph] == 1, "beacon should start in the same-size tier")

-- Each tier runs for exactly its face count of showings, then the next tier
-- takes over, wrapping back to the first. The starting face above already
-- consumed one showing of tier 1, so the loop picks up one short of a full
-- tier. The face must stay in the expected tier the whole time, and a redraw
-- or elapsed-time change must not advance it.
local tier, left = 1, tier_len(1) - 1
local seen = {}
for i = 1, 200 do
  seen[tier] = true
  tick()
  vim.wait(1) -- run the scheduled timer callback
  glyph = face()
  assert(tier_of[glyph] == tier, "face escaped tier " .. tier .. " on tick " .. i)
  state.live[buf].since = os.time() - i * 100
  assert(face() == glyph, "redraw or elapsed time changed the face")
  left = left - 1
  if left == 0 then
    tier = tier % #spinner.groups + 1
    left = tier_len(tier)
  end
end
assert(seen[1] and seen[2], "beacon should cycle through both size tiers")

state.running[buf] = nil
spinner.stop_if_idle()
print("OK winbar_spinner_order")
