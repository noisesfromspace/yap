local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime! plugin/yap.lua")
local yap = require("harness")
local document = require("harness.model.document")
local session = require("harness.session")
local frontmatter = require("harness.model.frontmatter")
local paths = require("harness.path")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "def/default-m", flash = "" }})

-- 1. new() writes the frontmatter with the initial combo + history
local buf = yap.new({ provider = "zeta", model = "m1" })
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(lines[1] == "---", "new buffer must start with frontmatter: " .. tostring(lines[1]))
local fm = frontmatter.parse(lines)
assert(fm and fm.description == nil, "fresh session should have no description: " .. vim.inspect(fm and fm.description))
assert(fm and fm.provider == "zeta" and fm.model == "m1", "combo: " .. vim.inspect(fm))
assert(
  fm.reasoning_level == "medium",
  "new session should seed default reasoning_level: " .. vim.inspect(fm.reasoning_level)
)
assert(fm.created_at and fm.created_at ~= "", "created_at missing: " .. vim.inspect(fm))
assert(fm.updated_at and fm.updated_at ~= "", "updated_at missing: " .. vim.inspect(fm))
assert(fm.created_cwd == vim.fs.normalize(vim.fn.getcwd()), "cwd not recorded: " .. vim.inspect(fm.created_cwd))
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
  frontmatter.render({
    provider = "zeta",
    model = "m1",
    models = fm.models,
    created_at = created,
    description = "Implement session descriptions",
  })
)

-- 2. document.messages ignores the frontmatter (it is not a message)
local msgs = document.messages(buf)
assert(#msgs == 1 and msgs[1].role == "system", "frontmatter leaked into messages")

-- 3. change_model appends to the history and updates the combo
yap.change_model("alpha/m2")
lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
fm = frontmatter.parse(lines)
assert(fm.provider == "alpha" and fm.model == "m2", "combo not updated: " .. vim.inspect(fm))
assert(fm.created_at == created, "created_at changed: " .. vim.inspect(fm.created_at))
assert(
  fm.created_cwd == vim.fs.normalize(vim.fn.getcwd()),
  "cwd not preserved across a rewrite: " .. vim.inspect(fm.created_cwd)
)
assert(fm.description == "Implement session descriptions", "description lost: " .. vim.inspect(fm))
assert(vim.deep_equal(fm.models, { "zeta/m1", "alpha/m2" }), "history not appended: " .. vim.inspect(fm.models))
local bar = yap.winbar(buf)
assert(bar:find("Implement session descriptions", 1, true), "description missing from winbar: " .. bar)
local long_description = "Improve the session toolbar without crowding out important status information"
vim.api.nvim_buf_set_lines(
  buf,
  0,
  e,
  false,
  frontmatter.render({
    provider = "alpha",
    model = "m2",
    models = fm.models,
    created_at = created,
    description = long_description,
  })
)
bar = yap.winbar(buf)
assert(bar:find("Improve the session toolbar without cro…", 1, true), "description not truncated: " .. bar)
assert(not bar:find(long_description, 1, true), "full description leaked into winbar: " .. bar)
vim.api.nvim_buf_set_lines(
  buf,
  0,
  e,
  false,
  frontmatter.render({
    provider = "alpha",
    model = "m2",
    models = fm.models,
    created_at = created,
    description = "Implement session descriptions",
  })
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
assert(
  frontmatter.parse(vim.fn.readfile(path)).created_cwd == vim.fs.normalize(vim.fn.getcwd()),
  "cwd not written to the session file"
)
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
  all_items[1].text == paths.project_cwd(path) .. "  Implement session descriptions",
  "all-project label should show decoded cwd: " .. all_items[1].text
)
assert(items[1].models and #items[1].models == 2, "history not surfaced: " .. vim.inspect(items[1].models))

-- Assets working files (e.g. a fetched .md) are never sessions: the list must
-- not grow when a stray markdown lands inside a session's assets folder.
vim.fn.mkdir(paths.assets_dir(buf2), "p")
vim.fn.writefile({ "# not a transcript" }, paths.assets_dir(buf2) .. "/stray.md")
assert(#session.list("cwd") == 1, "assets markdown leaked into the session list")

-- 7. updated_at + turns render and parse back
local updated_block = frontmatter.render({
  provider = "zeta",
  model = "m1",
  models = { "zeta/m1" },
  created_at = created,
  updated_at = "2025-09-29T19:24:01Z",
  turns = 14,
  created_cwd = "/tmp/project",
})
local updated_fm = frontmatter.parse(updated_block)
assert(updated_fm.created_cwd == "/tmp/project", "cwd not roundtripped: " .. vim.inspect(updated_fm.created_cwd))
assert(
  updated_fm.updated_at == "2025-09-29T19:24:01Z",
  "updated_at not roundtripped: " .. vim.inspect(updated_fm.updated_at)
)
assert(updated_fm.turns == 14, "turns not roundtripped: " .. vim.inspect(updated_fm.turns))
local links = frontmatter.parse(frontmatter.render({
  provider = "zeta",
  model = "m1",
  models = {},
  created_at = created,
  turns = 0,
  created_cwd = "/tmp/project",
  forked_from = "/tmp/source",
  subagent_parent = "/tmp/parent",
}))
assert(
  links.forked_from == "/tmp/source" and links.subagent_parent == "/tmp/parent",
  "links not roundtripped"
)
local tools_block = frontmatter.render({
  provider = "zeta",
  model = "m1",
  models = {},
  created_at = created,
  tools = { "read", "search", "glob" },
  turns = 0,
  created_cwd = "/tmp/project",
})
local tools_idx = nil
for i, l in ipairs(tools_block) do
  if l == "tools:" then
    tools_idx = i
  end
end
assert(
  tools_idx and tools_block[tools_idx + 1] == "  - read",
  "tools must render as a YAML list: " .. vim.inspect(tools_block)
)
local tools_fm = frontmatter.parse(tools_block)
assert(
  vim.deep_equal(tools_fm.tools, { "read", "search", "glob" }),
  "tools list not roundtripped: " .. vim.inspect(tools_fm.tools)
)
-- reasoning_level is the live, hand-editable choice.
local knobs_block = frontmatter.render({
  provider = "zeta",
  model = "m1",
  models = {},
  created_at = created,
  turns = 0,
  created_cwd = "/tmp/project",
  reasoning_level = "high",
})
local knobs_fm = frontmatter.parse(knobs_block)
assert(
  knobs_fm.reasoning_level == "high",
  "reasoning_level not roundtripped: " .. vim.inspect(knobs_fm.reasoning_level)
)
local saw_level = false
for _, l in ipairs(knobs_block) do
  if l == "reasoning_level: high" then
    saw_level = true
  end
end
assert(saw_level, "reasoning_level line missing: " .. vim.inspect(knobs_block))
local plain_fm = frontmatter.parse(frontmatter.render({
  provider = "zeta",
  model = "m1",
  models = {},
  created_at = created,
  turns = 0,
  created_cwd = "/tmp/project",
}))
assert(plain_fm.reasoning_level == nil, "absent knob should parse as nil: " .. vim.inspect(plain_fm))

-- 8. a renamed transcript's filename is the session's permanent title. Every
-- view shows it instead of the generated description, which only labels an
-- unrenamed session.md.
local renamed_path = vim.fn.expand("~") .. "/.config/yap/sessions/-opt-code-yap/fix-picker/my-title.md"
local plain_path = vim.fn.expand("~") .. "/.config/yap/sessions/-opt-code-yap/fix-picker/session.md"
assert(session.file_title(renamed_path) == "my-title", "filename title: " .. tostring(session.file_title(renamed_path)))
assert(session.file_title(plain_path) == nil, "session.md carries no filename title")
assert(
  session.label(renamed_path, "Generated description") == "my-title",
  "filename should win when renamed: " .. session.label(renamed_path, "Generated description")
)
assert(
  session.label(plain_path, "Generated description") == "Generated description",
  "description should label an unrenamed transcript: " .. session.label(plain_path, "Generated description")
)
assert(
  session.label(plain_path, nil) == "fix-picker",
  "directory name should be the fallback: " .. session.label(plain_path, nil)
)
assert(
  session.label(renamed_path, "Generated description", "/srv/app") == "/srv/app  my-title",
  "filename title should keep the cwd prefix: " .. session.label(renamed_path, "Generated description", "/srv/app")
)

-- 9. save stamps a turn count from the `# @user` headings
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
