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
w(tmp .. "/skills/frontend.md", "---\ndescription: Review frontend code\n---\nUse semantic HTML.\n")

yap.setup({
  bin = ROOT .. "/yap",
  templates_dir = tmp .. "/templates",
  skills_dir = tmp .. "/skills",
  skills_intro = true,
})

-- a new chat lists skills in its system block
local buf = yap.new()
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(text:match("## Skills"), "skills intro missing: " .. text)
assert(text:match("frontend: Review frontend code"), "skill description missing: " .. text)

-- a skill merges into the system block, not a new # @user
yap.insert("frontend")
text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(text:match("Use semantic HTML%."), "skill body not merged: " .. text)
assert(select(2, text:gsub("# @user", "")) == 1, "unexpected # @user count: " .. text)
local sys, usr = text:find("# @system"), text:find("# @user")
local body = text:find("Use semantic HTML", 1, true)
assert(sys and usr and body and body > sys and body < usr, "skill body outside system block: " .. text)

-- a template appends as a # @user block
yap.insert("compact")
text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(select(2, text:gsub("# @user", "")) == 2, "template not appended as user: " .. text)
assert(text:match("Summarize the conversation above%."), "template body missing: " .. text)

-- still parses: system + the template's user message (the empty original
-- # @user block is dropped, R6)
local roles = {}
local msgs = yap.parse_buffer(buf)
for _, m in ipairs(msgs) do
  roles[#roles + 1] = m.role
end
assert(vim.deep_equal(roles, { "system", "user" }), "parse roles: " .. vim.inspect(roles))
assert(msgs[2].content == "Summarize the conversation above.", "user content: " .. msgs[2].content)

print("OK template")
