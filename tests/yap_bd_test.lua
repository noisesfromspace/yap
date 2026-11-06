-- Session deletion uses native Neovim landing and still cleans up child drawers.
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

-- Status must not override Neovim's alternate-buffer choice. In particular,
-- a waiting or running session must not steal focus from a recent file.
local waiting = yap.new()
state.awaiting[waiting] = true
local running = yap.new()
state.running[running] = { kill = function() end }
local file = open_file()
yap.new()
assert(vim.fn.bufnr("#") == file, "file should be the alternate buffer")
vim.cmd("bd")
vim.wait(50)
assert(current() == file, "session status overrode ordinary :bd landing: " .. cur_name())
state.running[running] = nil

-- An idle session is a normal alternate buffer, too.
local idle = yap.new()
yap.new()
assert(vim.fn.bufnr("#") == idle, "idle session should be the alternate buffer")
vim.cmd("bd")
vim.wait(50)
assert(current() == idle, "ordinary :bd skipped the idle session: " .. cur_name())

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

-- Deleting a session leaves its panels open (manual control): the scratch
-- and tail windows stay, and their buffers persist for a later reopen — they
-- belong to the session, not the deleted buffer.
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
    return #vim.fn.win_findbuf(scratch) == 1 and #vim.fn.win_findbuf(tail) == 1
  end),
  "deleting the session closed its panels"
)
assert(vim.api.nvim_buf_is_valid(scratch), "scratch buffer was wiped on :bd")
assert(vim.api.nvim_buf_is_valid(tail), "tail viewer buffer was wiped on :bd")

-- Split handling belongs to Neovim too; the alternate listed session
-- remains usable whether Neovim reuses or closes a duplicate window.
local visible = yap.new()
vim.cmd("vsplit")
yap.new()
vim.cmd("bd")
vim.wait(50)
assert(vim.api.nvim_buf_is_valid(visible), ":bd deleted the alternate session")
assert(current() == visible, ":bd did not use the listed alternate session")
vim.cmd("only")

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
