-- <leader>r / <leader>w are global (they list sessions across buffers, so
-- they must work from any file), and opening a session file directly
-- (nvim ~/.yap/sessions/.../x.md) adopts it as a managed yap buffer:
-- unlisted, keymapped, tail sidecar attached.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local session = require("harness.session")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

-- global keymaps (not buffer-local)
local globals = {}
for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
  if m.desc then
    globals[m.desc] = true
  end
end
assert(globals["yap: running and idle sessions"], "no global <leader>r (yap: running and idle sessions) map")
assert(globals["yap: sessions needing attention"], "no global <leader>w (yap: sessions needing attention) map")

-- a saved session, reopened by plain :edit (the `nvim file.md` path), is
-- adopted: marked yap, unlisted, buffer-local keymaps in place
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @system", "", "hi", "", "# @user", "" })
session.save(buf)
local path = vim.b[buf].yap_path
assert(path and vim.fn.filereadable(path) == 1, "session not saved")
vim.cmd("bwipeout!")
local early_unlisted
local watch = vim.api.nvim_create_autocmd("BufNew", {
  callback = function(args)
    if vim.api.nvim_buf_get_name(args.buf) == path then
      early_unlisted = not vim.bo[args.buf].buflisted
    end
  end,
})
-- Plain :edit is also the path file explorers use after choosing a file:
-- it must be hidden from ordinary buffer lists early, then fully adopted.
vim.cmd("edit " .. vim.fn.fnameescape(path))
vim.api.nvim_del_autocmd(watch)
local b = vim.api.nvim_get_current_buf()
assert(early_unlisted, "session should be unlisted as soon as its named buffer is created")
assert(vim.b[b].yap == true, "direct/file-explorer open session not marked as yap")
assert(not vim.bo[b].buflisted, "adopted session should be unlisted")
assert(vim.b[b].yap_path == path, "yap_path not set on adopt: " .. tostring(vim.b[b].yap_path))
local mapped = false
for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
  if m.desc == "yap: send" then
    mapped = true
  end
end
assert(mapped, "adopted session has no buffer-local keymaps")
print("OK adopt")
