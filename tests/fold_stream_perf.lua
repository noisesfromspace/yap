-- Measure fold reconciliation on a long transcript, including the synchronous
-- stream-append projection (the existing tests/perf.lua times only parse/text).
-- Run: nvim --headless -u NONE -l tests/fold_stream_perf.lua
local root = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(root)
local fold = require("harness.ui.fold")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local yap = require("harness")
yap.setup({ sessions_dir = dir, model_groups = { agent = "mock/m1", flash = "" } })
local buf = yap.new()
local count = tonumber(vim.env.PERF_FOLDS) or 250
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
for i = 1, count do
  vim.list_extend(
    lines,
    { "# @user", "question " .. i, "", "# @assistant", "<!-- yap:thinking", "thought", "-->", "answer " .. i, "" }
  )
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
fold.set_view_level(2)
local function measure(label, fn)
  local start = vim.uv.hrtime()
  for _ = 1, 20 do
    fn()
  end
  print(string.format("%s (%d turns): %.2f ms/append", label, count, (vim.uv.hrtime() - start) / 20e6))
end
measure("reconcile after streamed text", function()
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "stream chunk" })
  fold.after_append(buf, { "stream chunk" })
end)
measure("reconcile after new region", function()
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "<!-- yap:thinking", "thought", "-->" })
  fold.after_append(buf, { "<!-- yap:thinking", "thought", "-->" })
end)
