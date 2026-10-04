vim.g.mapleader = ","
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({
  models = { "mock/m1" },
  keymaps = { stop = "<M-Esc>", send = "" },
})
local buf
vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function(ev)
    -- Model touchup.nvim's markdown-local indent mapping, installed on FileType.
    vim.keymap.set("i", "<C-t>", "<Plug>(touchup-indent)", {
      buffer = ev.buf,
      desc = "touchup indent",
    })
  end,
})
buf = yap.new()

local function get_lhs(mode, desc)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if m.desc == desc then
      return m.lhs
    end
  end
  return nil
end

assert(get_lhs("n", "yap: stop in-flight request") == "<M-Esc>", "custom stop keymap not applied")
assert(get_lhs("n", "yap: send") == nil, "empty send keymap should disable the normal-mode binding")
assert(get_lhs("i", "yap: send") == nil, "empty send keymap should disable the insert-mode binding")
assert(get_lhs("n", "yap: change model") ~= nil, "unspecified keymap default was not kept")
assert(get_lhs("n", "yap: insert template or skill") == ",t", "insert keymap is not <leader>t in normal mode")
assert(get_lhs("i", "yap: insert template or skill") == ",t", "insert keymap is not <leader>t in insert mode")
assert(get_lhs("i", "touchup indent") == "<C-T>", "Yap overrode touchup's insert-mode Ctrl-T mapping")
print("OK keymap")
