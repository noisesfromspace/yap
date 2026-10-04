-- :bd on a yap session buffer lands on the buffer the user came from (the
-- last session), not on the empty "No Name" buffer Neovim's "deleting the
-- last listed buffer" path produces. Session buffers are unlisted, so
-- Neovim's own replacement-buffer search skips them.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

local function current()
  return vim.api.nvim_get_current_buf()
end

-- Open session A, then B; deleting B must return to A (the last session).
local a = yap.new()
local b = yap.new()
assert(current() == b, "B should be current")
assert(a ~= b, "expected two distinct session buffers")

vim.cmd("bd")
local ok = vim.wait(2000, function()
  return current() == a
end)
assert(ok, "after :bd B, expected to land on session A, got " .. vim.api.nvim_buf_get_name(0))

-- No stray empty [No Name] buffer lingers in the buffer list.
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(buf) and buf ~= current() then
    assert(vim.api.nvim_buf_get_name(buf) ~= "", "stray [No Name] buffer left after :bd")
  end
end

-- With a listed file in the mix, :bd still returns to the previous buffer
-- and does not fabricate an empty buffer.
local file = vim.fn.tempname()
vim.fn.writefile({ "hello" }, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))
local filebuf = current()
local c = yap.new()
vim.cmd("bd")
ok = vim.wait(2000, function()
  return current() == filebuf
end)
assert(ok, "after :bd over a listed file, expected to return to it, got " .. vim.api.nvim_buf_get_name(0))

print("OK bd")
