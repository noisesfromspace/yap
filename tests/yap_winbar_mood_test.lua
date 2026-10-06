-- Drive the visual timer without waiting for real seconds: faces should
-- make complete emotional arcs, regardless of how long a tool has run.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local winbar = require("harness.winbar")
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
winbar.spinner_start()
vim.uv.new_timer = original_timer

local center = { [0xEE89] = true, [0xEE4C] = true, [0xEE6E] = true, [0xEE42] = true, [0xEE6D] = true }
local extremes = { [0xEDA9] = true, [0xEE80] = true, [0xEE49] = true, [0xEE4B] = true,
  [0xEE4E] = true, [0xEE50] = true, [0xEE62] = true, [0xEE63] = true, [0xEE64] = true,
  [0xEE65] = true, [0xEE30] = true, [0xEE7B] = true }
local function face()
  local bar = yap.winbar(buf)
  for _, glyph in ipairs(winbar.spinner_frames) do
    if bar:find(glyph, 1, true) then
      return vim.fn.char2nr(glyph)
    end
  end
  error("missing mood face: " .. bar)
end
assert(center[face()], "long-running tool should begin in the middle mood")
local saw_extreme, returned = false, false
for i = 1, 500 do
  tick()
  vim.wait(1) -- run the scheduled timer callback
  local glyph = face()
  if i < 15 then
    assert(center[glyph], "mood left the middle before its initial rest")
  end
  if extremes[glyph] then
    saw_extreme = true
  elseif saw_extreme and (glyph == 0xEE89 or glyph == 0xEE4C) then
    returned = true -- these two faces occur only in the middle pool
  end
  -- A redraw or a change to the tool start time must not advance the mood.
  state.live[buf].since = os.time() - i * 100
  assert(face() == glyph, "redraw or elapsed time changed the face")
end
assert(saw_extreme and returned, "mood did not travel to an extreme and return to the middle")
state.running[buf] = nil
winbar.spinner_stop_if_idle()
state.running[buf] = {}
winbar.spinner_start()
assert(center[face()], "new run did not reset to middle mood")
state.running[buf] = nil
winbar.spinner_stop_if_idle()
