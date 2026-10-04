local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
vim.cmd("runtime plugin/yap.lua")
local paths = require("harness.path")

local buf = yap.new()
local original = vim.b[buf].yap_path
local original_text = table.concat(vim.fn.readfile(original), "\n")

vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "fork-only change" })
vim.cmd("YapFork forked")

local fork = vim.b[buf].yap_path
local expected_dir = paths.session_dir(vim.b[buf].yap_project_cwd)
assert(fork == expected_dir .. "/forked.md", "fork outside project session directory: " .. fork)
assert(vim.fn.filereadable(fork) == 1, "fork not saved")
assert(table.concat(vim.fn.readfile(original), "\n") == original_text, "original session changed")
assert(table.concat(vim.fn.readfile(fork), "\n"):match("fork%-only change"), "fork content missing")

local path, err = require("harness.session").fork(buf, "forked")
assert(not path and err:match("already exists"), "existing fork should not be overwritten")
local generated = assert(require("harness.session").fork(buf))
assert(generated:match("^" .. vim.pesc(expected_dir) .. "/%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%x%x%x%x%.md$"), "unexpected generated fork name: " .. generated)

print("OK fork")
