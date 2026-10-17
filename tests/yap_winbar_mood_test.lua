-- The beacon walks the size tiers deterministically: every same-size face is
-- shown once before the bigger tier begins, and the face only changes on the
-- spinner tick — never on a redraw or on tool elapsed time.
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

local function face()
  local bar = yap.winbar(buf)
  for _, glyph in ipairs(spinner.spinner_frames) do
    if bar:find(glyph, 1, true) then
      return glyph
    end
  end
  error("missing face: " .. bar)
end

local frames = spinner.spinner_frames
assert(#spinner.groups[1].faces + #spinner.groups[2].faces == #frames, "tiers must cover every frame")

-- The beacon starts on the smallest face, and a redraw or a change to the
-- tool start time must not advance it.
local glyph = face()
assert(glyph == frames[1], "beacon should start on the smallest face")
state.live[buf].since = os.time() - 500
assert(face() == glyph, "redraw or elapsed time changed the face")

-- Walk a full cycle plus a wrap: the face advances exactly one slot per tick,
-- all of the first (same-size) tier before the bigger tier, then it wraps.
for i = 1, #frames do
  tick()
  vim.wait(1) -- run the scheduled timer callback
  assert(face() == frames[i % #frames + 1], "face out of order after " .. i .. " ticks")
end

state.running[buf] = nil
spinner.stop_if_idle()
print("OK winbar_spinner_order")
