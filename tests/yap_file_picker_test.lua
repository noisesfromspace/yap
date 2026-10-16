local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })

local cwd = vim.fn.tempname()
vim.fn.mkdir(cwd .. "/src", "p")
vim.fn.writefile({ "return true" }, cwd .. "/src/example.lua")
vim.cmd.cd(vim.fn.fnameescape(cwd))

local buf = yap.new()
local function has_mapping(buffer, mode, desc)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buffer, mode)) do
    if map.desc == desc then
      return true
    end
  end
  return false
end
assert(has_mapping(buf, "i", "yap: insert file reference"), "session buffer has no insert-mode file picker shortcut")
assert(not has_mapping(buf, "n", "yap: insert file reference"), "session buffer has a normal-mode file picker shortcut")
local original_select = vim.ui.select
local listed
vim.ui.select = function(items, _, on_choice)
  listed = items
  on_choice("src/example.lua")
end

yap.insert_file()
local inserted = vim.wait(3000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  return text:find("@src/example.lua ", 1, true) ~= nil
end, 10)
assert(inserted, "file reference was not inserted in chat")
assert(listed and vim.tbl_contains(listed, "src/example.lua"), "picker did not search current :pwd")

-- The same action and shortcut are installed in the session's notes file.
yap.scratch_toggle()
local scratch = vim.api.nvim_get_current_buf()
local n = vim.api.nvim_buf_line_count(scratch)
vim.api.nvim_buf_set_lines(scratch, n, n, false, { "" })
vim.api.nvim_win_set_cursor(0, { n + 1, 0 })
listed = nil
yap.insert_file()
local queued = vim.wait(3000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(scratch, 0, -1, false), "\n")
  return text:find("@src/example.lua ", 1, true) ~= nil
end, 10)
assert(queued, "file reference was not inserted in queue")
assert(listed and vim.tbl_contains(listed, "src/example.lua"), "queue picker did not search current :pwd")

assert(has_mapping(scratch, "i", "yap: insert file reference"), "queue buffer has no insert-mode file picker shortcut")
assert(
  not has_mapping(scratch, "n", "yap: insert file reference"),
  "queue buffer has a normal-mode file picker shortcut"
)
vim.ui.select = original_select
print("OK file picker")
