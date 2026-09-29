local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime! plugin/yap.lua")
local yap = require("harness")
local session = require("harness.session")
local frontmatter = require("harness.frontmatter")
yap.setup({ bin = ROOT .. "/yap", provider = "def", model = "default-m" })

-- 1. new() writes the frontmatter with the initial combo + history
local buf = yap.new({ provider = "zeta", model = "m1" })
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(lines[1] == "---", "new buffer must start with frontmatter: " .. tostring(lines[1]))
local fm = frontmatter.parse(lines)
assert(fm and fm.provider == "zeta" and fm.model == "m1", "combo: " .. vim.inspect(fm))
assert(fm.created_at and fm.created_at ~= "", "created_at missing: " .. vim.inspect(fm))
assert(vim.deep_equal(fm.models, { "zeta/m1" }), "history: " .. vim.inspect(fm and fm.models))
local created = fm.created_at

-- 2. parse_buffer ignores the frontmatter (it is not a message)
local msgs = yap.parse_buffer(buf)
assert(#msgs == 1 and msgs[1].role == "system", "frontmatter leaked into messages")

-- 3. change_model appends to the history and updates the combo
yap.change_model("alpha/m2")
lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
fm = frontmatter.parse(lines)
assert(fm.provider == "alpha" and fm.model == "m2", "combo not updated: " .. vim.inspect(fm))
assert(fm.created_at == created, "created_at changed: " .. vim.inspect(fm.created_at))
assert(vim.deep_equal(fm.models, { "zeta/m1", "alpha/m2" }), "history not appended: " .. vim.inspect(fm.models))

-- 4. switching to the same combo is a no-op for the history
yap.change_model("alpha/m2")
lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
fm = frontmatter.parse(lines)
assert(vim.deep_equal(fm.models, { "zeta/m1", "alpha/m2" }), "duplicate combo: " .. vim.inspect(fm.models))

-- 5. the session file persists it, and open restores the combo
session.save(buf)
local path = vim.b[buf].yap_path
assert(path and vim.fn.filereadable(path) == 1, "session not saved")
vim.cmd("bwipeout!")
yap.open(path)
local buf2 = vim.api.nvim_get_current_buf()
assert(
  vim.b[buf2].yap_provider == "alpha" and vim.b[buf2].yap_model == "m2",
  "open did not restore combo: " .. tostring(vim.b[buf2].yap_provider) .. "/" .. tostring(vim.b[buf2].yap_model)
)

-- 6. the picker surfaces the model and the history
local items = session.list("cwd")
assert(#items == 1, "expected 1 session, got " .. #items)
assert(items[1].text:match("alpha/m2"), "model missing from label: " .. items[1].text)
assert(items[1].models and #items[1].models == 2, "history not surfaced: " .. vim.inspect(items[1].models))

-- 7. a legacy file without frontmatter keeps the config default and is
--    left untouched (open must not inject a dirtying edit)
local legacy = vim.fn.tempname() .. ".md"
vim.fn.writefile({ "# @system", "", "hi", "", "# @user", "" }, legacy)
vim.cmd("bwipeout!")
yap.open(legacy)
local buf3 = vim.api.nvim_get_current_buf()
assert(
  vim.b[buf3].yap_provider == nil and vim.b[buf3].yap_model == nil,
  "legacy open should not set buffer combo vars"
)
assert(yap.winbar(buf3):match("def/default%-m"), "legacy open should fall back to config in the winbar")
assert(
  vim.api.nvim_buf_get_lines(buf3, 0, 1, false)[1] == "# @system",
  "open must not inject frontmatter into legacy files"
)

print("OK frontmatter")
