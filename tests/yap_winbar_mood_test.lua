-- Drive the visual timer without waiting for real seconds: the beacon should
-- randomly loop through the existing emotion groups, and only change on the
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

-- Map each face to its emotion group so the test can assert the beacon
-- travels across groups rather than parking in one.
local group_of = {}
for gi, group in ipairs(spinner.groups) do
  for _, glyph in ipairs(group.faces) do
    group_of[glyph] = gi
  end
end
local function face()
  local bar = yap.winbar(buf)
  for _, glyph in ipairs(spinner.spinner_frames) do
    if bar:find(glyph, 1, true) then
      return glyph
    end
  end
  error("missing mood face: " .. bar)
end

local glyph = face()
assert(group_of[glyph], "beacon should start on some emotion group")
local seen_groups = { [group_of[glyph]] = true }
for i = 1, 200 do
  tick()
  vim.wait(1) -- run the scheduled timer callback
  glyph = face()
  seen_groups[group_of[glyph]] = true
  -- A redraw or a change to the tool start time must not advance the face.
  state.live[buf].since = os.time() - i * 100
  assert(face() == glyph, "redraw or elapsed time changed the face")
end
local n_groups = 0
for _ in pairs(seen_groups) do
  n_groups = n_groups + 1
end
assert(n_groups >= 3, "beacon did not loop through multiple emotion groups: " .. n_groups)

state.running[buf] = nil
spinner.stop_if_idle()
print("OK winbar_mood")
