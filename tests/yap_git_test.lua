local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/tests/mock_git.py" })

local original = vim.fn.getcwd()
local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "git status?" })

local function user_blocks()
  local n = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == "# @user" then
      n = n + 1
    end
  end
  return n
end

local function send_from(dir)
  local before = user_blocks()
  vim.cmd.cd(vim.fn.fnameescape(dir))
  yap.send()
  -- A completed turn appends another "# @user" block (close_stream), so
  -- wait for that rather than a fixed count that a prior turn already met.
  assert(
    vim.wait(2000, function()
      return user_blocks() > before
    end, 20),
    "send did not complete from " .. dir
  )
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- Inside a git repo the snapshot is injected (the mock echoes it).
local in_repo = send_from(ROOT)
assert(in_repo:find("Git: ", 1, true), "git snapshot missing inside a git repo")

-- Outside a repo the snapshot is omitted (the mock reports the sentinel).
local outside = vim.fn.tempname()
vim.fn.mkdir(outside, "p")
local not_repo = send_from(outside)
assert(not_repo:find("NO_GIT", 1, true), "git snapshot present outside a git repo")

vim.cmd.cd(vim.fn.fnameescape(original))

-- Injected system messages never leak into the session buffer.
assert(in_repo:find("# About Yap", 1, true) == nil, "injected About Yap leaked into session buffer")
assert(in_repo:find("Current Neovim working directory:", 1, true) == nil, "injected cwd leaked into session buffer")
print("OK git snapshot injection")
