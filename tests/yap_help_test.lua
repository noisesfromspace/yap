local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ model_groups = { agent = "mock/m1", flash = "" }})
local buf = yap.new()

local function find_map(maps, lhs, desc)
  for _, map in ipairs(maps) do
    if map.lhs == lhs and map.desc == desc then
      return true
    end
  end
end

assert(find_map(vim.api.nvim_buf_get_keymap(buf, "n"), "g?", "yap: show shortcuts"), "g? shortcut missing")
local panel, win = yap.show_keymaps(buf)
assert(vim.api.nvim_win_is_valid(win), "shortcut panel did not open")
local lines = table.concat(vim.api.nvim_buf_get_lines(panel, 0, -1, false), "\n")
assert(lines:match("Yap shortcuts %(current buffer%)"), "panel heading missing")
assert(lines:match("send"), "buffer-local shortcuts missing")
assert(lines:match("sessions"), "global shortcuts missing")
assert(lines:match("Search with /, n and N"), "native-search hint missing")
vim.api.nvim_win_close(win, true)
print("OK help panel")
