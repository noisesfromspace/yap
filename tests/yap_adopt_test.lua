-- Opening a session file directly (including from a file explorer) adopts
-- it as a listed, file-backed Yap buffer with local keymaps and a live tail.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local session = require("harness.session")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})

-- global keymaps (not buffer-local)
local globals = {}
for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
  if m.desc then
    globals[m.desc] = true
  end
end
assert(globals["yap: sessions"], "no global saved-session map")
assert(not globals["yap: instances"], "open-session picker should have no default global map")
assert(vim.fn.maparg("<leader>r", "n") == "", "Yap should leave <leader>r free by default")
assert(not globals["yap: sessions needing attention"], "stale global <leader>w map")

-- a saved session, reopened by plain :edit (the `nvim file.md` path), is
-- adopted: marked yap, listed, buffer-local keymaps in place
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @system", "", "hi", "", "# @user", "" })
session.save(buf)
local path = vim.b[buf].yap_path
assert(path and vim.fn.filereadable(path) == 1, "session not saved")
vim.cmd("bwipeout!")
local early_listed
local watch = vim.api.nvim_create_autocmd("BufAdd", {
  callback = function(args)
    if vim.api.nvim_buf_get_name(args.buf) == path then
      early_listed = vim.bo[args.buf].buflisted
    end
  end,
})
-- Plain :edit is also the path file explorers use after choosing a file:
-- it must keep its real filename and remain available in ordinary buffer lists.
vim.cmd("edit " .. vim.fn.fnameescape(path))
vim.api.nvim_del_autocmd(watch)
local b = vim.api.nvim_get_current_buf()
assert(early_listed, "ordinary session should enter the buffer list")
assert(vim.b[b].yap == true, "direct/file-explorer open session not marked as yap")
assert(vim.bo[b].buflisted, "adopted session should be listed")
assert(vim.api.nvim_buf_get_name(b) == path, "adoption replaced the real session filename")
assert(vim.fn.expand("%:p:h") == vim.fn.fnamemodify(path, ":h"), "explorers lost the session directory")
assert(vim.b[b].yap_path == path, "yap_path not set on adopt: " .. tostring(vim.b[b].yap_path))
local mapped = false
for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
  if m.desc == "yap: send" then
    mapped = true
  end
end
assert(mapped, "adopted session has no buffer-local keymaps")

-- Ordinary file commands keep the adopted session listed.
local function ls_shows(p)
  local target = vim.fn.bufnr(p)
  local out = vim.api.nvim_exec2("silent ls", { output = true }).output
  for line in out:gmatch("[^\n]+") do
    if tonumber(line:match("^%s*(%d+)")) == target then
      return true
    end
  end
  return false
end

vim.cmd("enew")
vim.cmd("badd " .. vim.fn.fnameescape(path))
assert(vim.bo[b].buflisted, "badd unlisted the session")
assert(ls_shows(path), "session missing from :ls after :badd")

vim.cmd("enew")
vim.cmd("args " .. vim.fn.fnameescape(path) .. " " .. vim.fn.fnameescape(vim.fn.tempname() .. ".md"))
vim.cmd("next")
assert(vim.bo[b].buflisted, "args/next unlisted the session")
vim.cmd("enew")
assert(ls_shows(path), "session missing from :ls after :args/:next")

print("OK adopt")
