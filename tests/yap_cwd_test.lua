local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/tests/mock_cwd.py" })

local original = vim.fn.getcwd()
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "where am I?" })

local function send_from(dir)
  vim.cmd.cd(vim.fn.fnameescape(dir))
  yap.send()
  assert(
    vim.wait(2000, function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local user_blocks = 0
      for _, line in ipairs(lines) do
        if line == "# @user" then
          user_blocks = user_blocks + 1
        end
      end
      return user_blocks >= 2 and vim.tbl_contains(lines, dir)
    end, 20),
    "response did not contain dynamic cwd: " .. dir
  )
end

send_from(ROOT)
local second = vim.fn.tempname()
vim.fn.mkdir(second, "p")
send_from(second)
vim.cmd.cd(vim.fn.fnameescape(original))

local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(text:find("Current Neovim working directory:", 1, true) == nil, "injected cwd leaked into chat buffer")
print("OK dynamic cwd")
