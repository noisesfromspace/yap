-- The beacon picks a random glyph each tick from a single uniform set, and
-- only changes on the spinner tick — never on a redraw or on tool elapsed
-- time. Every glyph shares one size, so the test only asserts the glyph stays
-- within the set and that the beacon roams it rather than parking on one face.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local spinner = require("harness.ui.spinner")
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

local function face()
  local bar = yap.winbar(buf)
  for _, glyph in ipairs(spinner.spinner_frames) do
    if bar:find(glyph, 1, true) then
      return glyph
    end
  end
  error("missing spinner glyph: " .. bar)
end

assert(#spinner.spinner_frames == 30, "expected 30 circle glyphs")

local glyph = face()
local seen = { [glyph] = true }
for i = 1, 200 do
  tick()
  vim.wait(1) -- run the scheduled timer callback
  glyph = face()
  seen[glyph] = true
  -- A redraw or a change to the tool start time must not advance the glyph.
  state.live[buf].since = os.time() - i * 100
  assert(face() == glyph, "redraw or elapsed time changed the glyph")
end

-- The beacon should roam the set, not park on one glyph.
local n_distinct = 0
for _ in pairs(seen) do
  n_distinct = n_distinct + 1
end
assert(n_distinct >= 5, "beacon did not vary its glyph: " .. n_distinct)

state.running[buf] = nil
spinner.stop_if_idle()
print("OK winbar_spinner")
