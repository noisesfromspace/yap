local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/templates", "p")
vim.fn.mkdir(dir .. "/skills", "p")
vim.fn.writefile({ "# @user", "", "run the suite" }, dir .. "/templates/check.md")
vim.fn.writefile({ "---", "description: A small skill", "---", "draft a plan" }, dir .. "/skills/plan.md")
vim.fn.writefile({ "review ${1:code}" }, dir .. "/templates/snippet.md")
local yap = require("harness")
yap.setup({ templates_dir = dir .. "/templates", skills_dir = dir .. "/skills" })
local owner = yap.new()
yap.scratch_toggle(owner)
local scratch = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- queue heading
require("harness.client.template").insert("check", { at_cursor = true })
local text = table.concat(vim.api.nvim_buf_get_lines(scratch, 0, -1, false), "\n")
assert(text:find("# @queue\n# @user\n\nrun the suite", 1, true), "template was not inserted in queue: " .. text)
assert(not yap.is_running(owner), "scratch template started a turn")
assert(
  not table.concat(vim.api.nvim_buf_get_lines(owner, 0, -1, false), "\n"):find("run the suite", 1, true),
  "template leaked to session"
)
vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- steer heading
require("harness.client.template").insert("plan", { at_cursor = true })
text = table.concat(vim.api.nvim_buf_get_lines(scratch, 0, -1, false), "\n")
assert(text:find("# @steer\ndraft a plan", 1, true), "skill was not inserted in steer: " .. text)
assert(not text:find("description: A small skill", 1, true), "skill frontmatter leaked")
local next_owner = yap.new()
yap.scratch_toggle(next_owner)
local next_scratch = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- last heading, no body line yet
require("harness.client.template").insert("snippet", { at_cursor = true })
assert(
  require("harness.client.scratch").section_text(next_scratch, "queue"):find("review code", 1, true),
  "snippet on final heading was not inserted in queue"
)
-- Away from a section heading, snippets and plain templates both insert above
-- the cursor line rather than on opposite sides of it.
local other = yap.new()
yap.scratch_toggle(other)
local notes = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(notes, 3, 3, false, { "existing draft" })
vim.api.nvim_win_set_cursor(0, { 4, 0 })
require("harness.client.template").insert("check", { at_cursor = true })
local lines = vim.api.nvim_buf_get_lines(notes, 0, -1, false)
assert(lines[4] == "# @user" and lines[6] == "run the suite" and lines[7] == "existing draft", vim.inspect(lines))
vim.api.nvim_win_set_cursor(0, { 7, 0 })
require("harness.client.template").insert("snippet", { at_cursor = true })
lines = vim.api.nvim_buf_get_lines(notes, 0, -1, false)
local joined = table.concat(lines, "\n")
local snippet_at, existing_at
for i, line in ipairs(lines) do
  if line == "review code" then
    snippet_at = i
  elseif line == "existing draft" then
    existing_at = i
  end
end
assert(snippet_at and existing_at and snippet_at < existing_at, "snippet did not insert above the cursor: " .. joined)
print("OK scratch templates insert without sending")
