-- :bd on a yap session buffer lands on a session awaiting a reply when one
-- is open, otherwise on a running session, then the last file accessed —
-- never on the empty "No Name" buffer Neovim's "deleting the last listed
-- buffer" path produces.
-- Session buffers are unlisted, so Neovim's own replacement-buffer search
-- skips them.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local state = require("harness.state")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})

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

-- A running session is preferred over a listed file when no session is
-- awaiting a reply.
state.awaiting[a] = nil -- A is now idle
local running_session = yap.new()
state.running[running_session] = { kill = function() end }
open_file()
local c = yap.new()
vim.cmd("bd")
assert(
  vim.wait(2000, function()
    return current() == running_session
  end),
  "after :bd C, expected the running session, got " .. cur_name()
)
state.running[running_session] = nil

-- An idle session is not a landing spot: go to the last file instead.
local filebuf3 = open_file()
local d = yap.new()
vim.cmd("bd")
assert(
  vim.wait(2000, function()
    return current() == filebuf3
  end),
  "after :bd D, expected the last file, got " .. cur_name()
)

-- A special window (explorer/quickfix/nofile) is not a landing spot either:
-- :bd skips it and lands on the last ordinary file buffer.
local function open_special()
  local special = vim.api.nvim_create_buf(true, false)
  vim.bo[special].buftype = "nofile"
  vim.api.nvim_set_current_buf(special)
  return special
end
local filebuf4 = open_file()
open_special() -- focus the explorer-like buffer after the file
local e = yap.new()
vim.cmd("bd")
assert(
  vim.wait(2000, function()
    return current() == filebuf4
  end),
  "after :bd E, expected the last file over the explorer, got " .. cur_name()
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

-- Deleting a session closes its open notes/tail drawers: the windows go
-- away, while the file-backed scratch and the tail viewer buffer persist for
-- a later reopen (they belong to the session, not the deleted buffer).
local s = yap.new()
yap.scratch_toggle()
local scratch = vim.api.nvim_get_current_buf()
vim.api.nvim_set_current_win(vim.fn.win_findbuf(s)[1])
yap.live(s)
local tail = vim.api.nvim_get_current_buf()
vim.api.nvim_set_current_win(vim.fn.win_findbuf(s)[1])
vim.cmd("bd")
assert(
  vim.wait(2000, function()
    return #vim.fn.win_findbuf(scratch) == 0 and #vim.fn.win_findbuf(tail) == 0
  end),
  "scratch/live drawers stayed open after :bd"
)
assert(vim.api.nvim_buf_is_valid(scratch), "scratch buffer was wiped on :bd")
assert(vim.api.nvim_buf_is_valid(tail), "tail viewer buffer was wiped on :bd")

-- A split already showing the fallback session must not be duplicated: the
-- fallback is skipped, so closing the current session collapses its
-- now-empty window and leaves the other split untouched.
local visible = yap.new()
state.awaiting[visible] = true
vim.cmd("vsplit")
local closing = yap.new()
state.awaiting[closing] = true
assert(vim.api.nvim_get_current_buf() == closing, "closing session should be current")
vim.cmd("bd")
assert(
  vim.wait(2000, function()
    return #vim.api.nvim_list_wins() == 1
      and vim.api.nvim_get_current_buf() == visible
      and #vim.fn.win_findbuf(visible) == 1
  end),
  "closing a session whose fallback is already visible should collapse the split, not duplicate"
)

-- A forced reload unloads and re-reads the file-backed buffer too, but is
-- not a session close: the session must remain current and usable afterward.
local reloaded = yap.new()
local reloaded_path = vim.b[reloaded].yap_path
vim.fn.writefile({ "reloaded from disk" }, reloaded_path)
vim.cmd("edit!")
assert(
  vim.wait(2000, function()
    return current() == reloaded and vim.api.nvim_buf_is_loaded(reloaded)
  end),
  "`:edit!` incorrectly redirected away from the reloaded session"
)
assert(vim.api.nvim_buf_is_valid(reloaded), "`:edit!` deleted the session buffer")
assert(vim.api.nvim_buf_get_name(reloaded) == reloaded_path, "`:edit!` changed the session path")
assert(
  vim.tbl_contains(vim.api.nvim_buf_get_lines(reloaded, 0, -1, false), "reloaded from disk"),
  "`:edit!` did not reload the session file"
)

print("OK bd")
