-- mini.test entry point for the yap Lua suite.
--
--   tests/run.sh                                     -- Go tests + this
--   nvim --headless -u NONE -l tests/minitest.lua    -- Lua suite only
--   YAP_TEST_FILTER=winbar nvim --headless -u NONE -l tests/minitest.lua
--
-- Every case in tests/suite.lua runs its tests/<name>.lua script in a fresh
-- child Neovim with an isolated $HOME, so the suite reports one result per
-- test file, a failing case prints the assertion that failed plus the session
-- home it was looking at, and the run exits non-zero on the first failure.
--
-- mini.nvim is not vendored: point YAP_MINI_NVIM at a checkout (tests/run.sh
-- resolves one from nixpkgs) or install it on the runtimepath yourself.
local TESTS = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")

local mini = vim.env.YAP_MINI_NVIM
if mini and mini ~= "" then
  vim.opt.rtp:prepend(mini)
end
local ok, MiniTest = pcall(require, "mini.test")
if not ok then
  error("mini.test is not on the runtimepath; set YAP_MINI_NVIM to a mini.nvim checkout", 0)
end
MiniTest.setup()

local filter = vim.env.YAP_TEST_FILTER

MiniTest.run({
  collect = {
    find_files = function()
      -- Native mini.test sets live beside the suite as tests/test_*.lua
      -- (files that return a MiniTest set); the ported scripts are driven
      -- from one set file.
      local files = vim.fn.globpath(TESTS, "test_*.lua", false, true)
      table.insert(files, 1, TESTS .. "/suite.lua")
      return files
    end,
    filter_cases = function(case)
      if not filter or filter == "" then
        return true
      end
      -- `desc` is the case's path of test-set keys, e.g.
      -- { 'suite.lua', 'yap_winbar_resize_test' }.
      return table.concat(case.desc, " "):find(filter, 1, true) ~= nil
    end,
  },
  -- Fail fast, as the old runner did: a suite that keeps going after a
  -- broken case spends minutes of stream timing on results nobody reads.
  execute = { stop_on_error = true },
})
