local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.mkdir(tmp .. "/templates", "p")
vim.fn.mkdir(tmp .. "/skills", "p")
local function w(path, text)
  local f = io.open(path, "w")
  f:write(text)
  f:close()
end
w(tmp .. "/templates/compact.md", "Summarize the conversation above.\n")
w(tmp .. "/templates/snip.md", "Investigate ${1:topic}\n")
w(tmp .. "/templates/empty.md", "\n")
w(tmp .. "/skills/frontend.md", "---\ndescription: Review frontend code\n---\nUse semantic HTML.\n")
vim.fn.mkdir(tmp .. "/agents", "p")
w(tmp .. "/agents/implementer.md", "---\nname: implementer\ndescription: Focused Yap implementation subagent.\n---\nImplement it.\n")
w(tmp .. "/agents/audit.md", "---\nmodel: deepseek/deepseek-flash\n---\nAudit it.\n")

yap.setup({
  bin = ROOT .. "/yap",
  templates_dir = tmp .. "/templates",
  skills_dir = tmp .. "/skills",
  agents_dir = tmp .. "/agents",
})

-- the skill/agent lists for the About Yap prefix resolve name + description,
-- falling back to the filename when a definition omits `name`
local skills = require("harness.template").skills_intro_lines()
assert(
  vim.deep_equal(skills, { "- frontend: Review frontend code" }),
  "skills intro: " .. vim.inspect(skills)
)
local agents = require("harness.template").agents_intro_lines()
assert(
  vim.deep_equal(agents, { "- audit", "- implementer: Focused Yap implementation subagent." }),
  "agents intro: " .. vim.inspect(agents)
)

-- a new buffer's system block holds only the user's system prompt: skills and
-- agents are injected in the About Yap prefix on send, not baked in here
local buf = yap.new()
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(not text:match("frontend: Review frontend code"), "skills list leaked into buffer: " .. text)

-- a skill merges into the system block, not a new # @user
yap.insert("frontend")
text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(text:match("Use semantic HTML%."), "skill body not merged: " .. text)
assert(select(2, text:gsub("# @user", "")) == 1, "unexpected # @user count: " .. text)
local sys, usr = text:find("# @system"), text:find("# @user")
local body = text:find("Use semantic HTML", 1, true)
assert(sys and usr and body and body > sys and body < usr, "skill body outside system block: " .. text)

-- a template appends as a # @user message, filling the existing trailing
-- # @user block instead of adding a second heading, and sends immediately
-- (already typed chat text would be merged the same way)
local original_send = yap.send
local sent = {}
yap.send = function(b)
  sent[#sent + 1] = b
end
yap.insert("compact")
assert(vim.deep_equal(sent, { buf }), "plain template was not sent exactly once")
text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(select(2, text:gsub("# @user", "")) == 1, "template added a duplicate # @user: " .. text)
assert(text:match("Summarize the conversation above%."), "template body missing: " .. text)

-- still parses: system + the template's user message
local roles = {}
local msgs = yap.parse_buffer(buf)
for _, m in ipairs(msgs) do
  roles[#roles + 1] = m.role
end
assert(vim.deep_equal(roles, { "system", "user" }), "parse roles: " .. vim.inspect(roles))
assert(msgs[2].content == "Summarize the conversation above.", "user content: " .. msgs[2].content)

-- a snippet template also fills the trailing # @user block (no duplicate
-- heading) and expands its tabstop placeholder
local buf2 = yap.new()
yap.insert("snip")
assert(#sent == 1, "snippet template sent before editing")
text = table.concat(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), "\n")
assert(select(2, text:gsub("# @user", "")) == 1, "snippet added a duplicate # @user: " .. text)
assert(text:match("Investigate topic"), "snippet body missing: " .. text)

-- A skill, raw at-cursor insertion and empty template must not send.
yap.insert("frontend")
yap.insert("compact", { at_cursor = true })
yap.insert("empty")
assert(#sent == 1, "non-prompt insertion sent unexpectedly")
yap.send = original_send

print("OK template")
