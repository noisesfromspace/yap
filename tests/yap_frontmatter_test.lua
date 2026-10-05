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
assert(fm.updated_at and fm.updated_at ~= "", "updated_at missing: " .. vim.inspect(fm))
assert(vim.deep_equal(fm.models, { "zeta/m1" }), "history: " .. vim.inspect(fm and fm.models))
local created = fm.created_at

-- descriptions survive ordinary frontmatter rewrites
local e = 1
while lines[e] ~= "---" or e == 1 do
  e = e + 1
end
vim.api.nvim_buf_set_lines(
  buf,
  0,
  e,
  false,
  frontmatter.render("zeta", "m1", fm.models, created, "Implement session descriptions")
)

-- 2. parse_buffer ignores the frontmatter (it is not a message)
local msgs = yap.parse_buffer(buf)
assert(#msgs == 1 and msgs[1].role == "system", "frontmatter leaked into messages")

-- 3. change_model appends to the history and updates the combo
yap.change_model("alpha/m2")
lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
fm = frontmatter.parse(lines)
assert(fm.provider == "alpha" and fm.model == "m2", "combo not updated: " .. vim.inspect(fm))
assert(fm.created_at == created, "created_at changed: " .. vim.inspect(fm.created_at))
assert(fm.description == "Implement session descriptions", "description lost: " .. vim.inspect(fm))
assert(vim.deep_equal(fm.models, { "zeta/m1", "alpha/m2" }), "history not appended: " .. vim.inspect(fm.models))
local bar = yap.winbar(buf)
local description_at =
  assert(bar:find("Implement session descriptions", 1, true), "description missing from winbar: " .. bar)
local model_at = assert(bar:find("alpha/m2", 1, true), "model missing from winbar: " .. bar)
assert(description_at < model_at, "description should precede model: " .. bar)
local long_description = "Improve the session toolbar without crowding out important status information"
vim.api.nvim_buf_set_lines(buf, 0, e, false, frontmatter.render("alpha", "m2", fm.models, created, long_description))
bar = yap.winbar(buf)
assert(bar:find("Improve the session toolbar without cro…", 1, true), "description not truncated: " .. bar)
assert(not bar:find(long_description, 1, true), "full description leaked into winbar: " .. bar)
vim.api.nvim_buf_set_lines(
  buf,
  0,
  e,
  false,
  frontmatter.render("alpha", "m2", fm.models, created, "Implement session descriptions")
)

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

-- 6. the picker shows only the description; model history remains metadata
local items = session.list("cwd")
assert(#items == 1, "expected 1 session, got " .. #items)
assert(
  items[1].text == "Implement session descriptions",
  "description should be the whole cwd label: " .. items[1].text
)
local all_items = session.list("all")
assert(
  all_items[1].text == "/opt/code/yap  Implement session descriptions",
  "all-project label should show decoded cwd: " .. all_items[1].text
)
assert(items[1].models and #items[1].models == 2, "history not surfaced: " .. vim.inspect(items[1].models))
local renamed_items = session.list("renamed")
assert(#renamed_items == 0,
  "description-labelled auto-named session should not appear in renamed scope: " .. vim.inspect(renamed_items))

-- 7. a legacy file without frontmatter keeps the config default and is
--    left untouched (open must not inject a dirtying edit)
local legacy = vim.fn.tempname() .. ".md"
vim.fn.writefile({ "# @system", "", "hi", "", "# @user", "" }, legacy)
vim.cmd("bwipeout!")
yap.open(legacy)
local buf3 = vim.api.nvim_get_current_buf()
assert(vim.b[buf3].yap_provider == nil and vim.b[buf3].yap_model == nil, "legacy open should not set buffer combo vars")
assert(yap.winbar(buf3):match("def/default%-m"), "legacy open should fall back to config in the winbar")
assert(
  vim.api.nvim_buf_get_lines(buf3, 0, 1, false)[1] == "# @system",
  "open must not inject frontmatter into legacy files"
)

-- 8. subagents + updated_at + turns render and parse back
local subagents_block = frontmatter.render("zeta", "m1", { "zeta/m1" }, created, nil, nil, nil, { "/tmp/a.md", "/tmp/b.md" }, "2025-09-29T19:24:01Z", 14)
local subagents_fm = frontmatter.parse(subagents_block)
assert(
  vim.deep_equal(subagents_fm.subagents, { "/tmp/a.md", "/tmp/b.md" }),
  "subagents not roundtripped: " .. vim.inspect(subagents_fm.subagents)
)
assert(subagents_fm.updated_at == "2025-09-29T19:24:01Z", "updated_at not roundtripped: " .. vim.inspect(subagents_fm.updated_at))
assert(subagents_fm.turns == 14, "turns not roundtripped: " .. vim.inspect(subagents_fm.turns))

-- 9. a :file-renamed session keeps its chosen name over the description
local named_path = vim.fn.expand("~") .. "/.yap/sessions/-opt-code-yap/fix-picker.md"
assert(
  session.label(named_path, "Generated description") == "fix-picker.md",
  "named session should use its filename: " .. session.label(named_path, "Generated description")
)
assert(
  session.label(named_path, "Generated description", "/opt/code/yap") == "/opt/code/yap  fix-picker.md",
  "named session label should keep the cwd prefix: " .. session.label(named_path, "Generated description", "/opt/code/yap")
)

-- 10. save stamps a turn count from the `# @user` headings
local buf4 = yap.new({ provider = "zeta", model = "m1" })
local body4 = vim.api.nvim_buf_get_lines(buf4, 0, -1, false)
vim.list_extend(body4, {
  "",
  "# @user",
  "",
  "first question",
  "",
  "# @assistant",
  "",
  "answer",
  "",
  "# @user",
  "",
  "second question",
})
vim.api.nvim_buf_set_lines(buf4, 0, -1, false, body4)
session.save(buf4)
local saved4 = frontmatter.parse(vim.fn.readfile(vim.b[buf4].yap_path))
assert(saved4.turns == 1, "save did not count completed replies: " .. vim.inspect(saved4))

print("OK frontmatter")
