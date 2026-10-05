-- :bd on a yap session buffer lands on a session awaiting a reply when one
-- is open, otherwise on the last file accessed — never on the empty "No
-- Name" buffer Neovim's "deleting the last listed buffer" path produces.
-- Session buffers are unlisted, so Neovim's own replacement-buffer search
-- skips them.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local state = require("harness.state")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

local function current()
  return vim.api.nvim_get_current_buf()
end

local function cur_name()
  return vim.api.nvim_buf_get_name(0)
end

local function open_file()
  local file = vim.fn.tempname()
  vim.fn.writefile({ "hello" }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  return current()
end

-- Only sessions open: deleting B lands on the waiting session A, and the
-- empty [No Name] buffer Neovim fabricates is dropped.
local a = yap.new()
state.awaiting[a] = true -- A's turn completed and awaits a reply
local b = yap.new()
assert(current() == b, "B should be current")
vim.cmd("bd")
assert(
  vim.wait(2000, function()
    return current() == a
  end),
  "after :bd B, expected waiting session A, got " .. cur_name()
)
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(buf) and buf ~= current() then
    assert(vim.api.nvim_buf_get_name(buf) ~= "", "stray [No Name] buffer left after :bd")
  end
end

-- A waiting session is preferred over a listed file.
open_file()
local b2 = yap.new()
vim.cmd("bd")
assert(
  vim.wait(2000, function()
    return current() == a
  end),
  "after :bd B2, expected waiting session A over the file, got " .. cur_name()
)

-- An idle session is not a landing spot: go to the last file instead.
state.awaiting[a] = nil -- A is now idle
local filebuf2 = open_file()
local c = yap.new()
vim.cmd("bd")
assert(
  vim.wait(2000, function()
    return current() == filebuf2
  end),
  "after :bd C, expected the last file, got " .. cur_name()
)

-- An unloaded parent also closes its hidden child sessions.
local parent = yap.new()
local child = yap.new()
vim.b[child].yap_subagent_parent = parent
state.awaiting[child] = true
vim.api.nvim_set_current_buf(parent)
vim.cmd("bd")
assert(
  vim.wait(2000, function()
    return not vim.api.nvim_buf_is_valid(child)
  end),
  "deleting a parent session should close its subagent buffer"
)
assert(state.running[child] == nil, "closed subagent should not keep a running request")

print("OK bd")
