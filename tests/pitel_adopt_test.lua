-- <leader>r / <leader>w are global (they list sessions across buffers, so
-- they must work from any file), and opening a session file directly
-- (nvim ~/.pitel/sessions/.../x.md) adopts it as a managed pitel buffer:
-- unlisted, keymapped, tail sidecar attached.
local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
local session = require("harness.session")
pitel.setup({ bin = ROOT .. "/pitel", provider = "mock", model = "m1" })

-- global keymaps (not buffer-local)
local globals = {}
for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
  if m.desc then
    globals[m.desc] = true
  end
end
assert(globals["pitel: sessions"], "no global <leader>r (pitel: sessions) map")
assert(globals["pitel: agents waiting for reply"], "no global <leader>w (pitel: agents waiting for reply) map")

-- a saved session, reopened by plain :edit (the `nvim file.md` path), is
-- adopted: marked pitel, unlisted, buffer-local keymaps in place
local buf = pitel.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @system", "", "hi", "", "# @user", "" })
session.save(buf)
local path = vim.b[buf].pitel_path
assert(path and vim.fn.filereadable(path) == 1, "session not saved")
vim.cmd("bwipeout!")
vim.cmd("edit " .. vim.fn.fnameescape(path))
local b = vim.api.nvim_get_current_buf()
assert(vim.b[b].pitel == true, "direct-open session not marked as pitel")
assert(not vim.bo[b].buflisted, "adopted session should be unlisted")
assert(vim.b[b].pitel_path == path, "pitel_path not set on adopt: " .. tostring(vim.b[b].pitel_path))
local mapped = false
for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
  if m.desc == "pitel: send" then
    mapped = true
  end
end
assert(mapped, "adopted session has no buffer-local keymaps")
print("OK adopt")
