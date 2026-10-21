-- Markdown colouring policy: a yap session buffer is coloured by Vim's
-- markdown syntax, not the tree-sitter highlighter, and the parser survives
-- (touchup renders from it).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local highlight = require("harness.session.highlight")

local api = vim.api

local lines = {
  "# @assistant", -- 1
  "Prose with **bold**, `code` and [a link](http://x).", -- 2
  "", -- 3
  '<!-- yap:tool {"id":"c1","name":"bash"} -->', -- 4
  "```diff", -- 5
  "-removed line", -- 6
  "+added line", -- 7
  "```", -- 8
  "```lua", -- 9
  "local x = 42 -- note", -- 10
  "```", -- 11
}

local buf = api.nvim_create_buf(false, true)
api.nvim_win_set_buf(api.nvim_get_current_win(), buf)
api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.b[buf].yap = true
vim.bo[buf].filetype = "markdown"

-- Stub what ftplugin/markdown.lua does on FileType (it does not run under
-- -u NONE), so the policy is tested against a live highlighter. A parser is
-- not guaranteed on the runtimepath (the suite's child has none), in which
-- case there is no highlighter to stop and only the syntax half is testable.
local has_parser = pcall(vim.treesitter.get_parser, buf, "markdown")
if has_parser then
  vim.treesitter.start(buf, "markdown")
  assert(vim.treesitter.highlighter.active[buf] ~= nil, "highlighter was not started")
end

highlight.apply(buf)

-- The policy: no highlighter, markdown syntax, parser still alive.
if has_parser then
  assert(vim.treesitter.highlighter.active[buf] == nil, "highlighter still active after apply")
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  assert(ok and parser, "parser must survive apply (touchup renders from it)")
end
assert(vim.bo[buf].syntax == "markdown", "syntax not set to markdown, got " .. tostring(vim.bo[buf].syntax))

-- Re-applying is a safe no-op.
highlight.apply(buf)
assert(vim.bo[buf].syntax == "markdown", "syntax lost on re-apply")
if has_parser then
  assert(vim.treesitter.highlighter.active[buf] == nil, "highlighter restarted on re-apply")
end

-- The fenced languages must be wired up (and a user's own list preserved,
-- not replaced), and the syntax must actually resolve: inline emphasis and
-- the fence's own language both colour.
vim.g.markdown_fenced_languages = { "javascript" }
highlight.apply(buf)
local fenced = table.concat(vim.g.markdown_fenced_languages, " ")
assert(fenced:find("diff", 1, true), "diff missing from markdown_fenced_languages: " .. fenced)
assert(fenced:find("lua", 1, true), "lua missing from markdown_fenced_languages: " .. fenced)
assert(fenced:find("javascript", 1, true), "user's fenced languages were replaced: " .. fenced)
assert(vim.bo[buf].syntax == "markdown", "syntax not set after fencing update")

local function groups_at(row, col)
  local id = vim.fn.synID(row, col, 1)
  return id ~= 0 and vim.fn.synIDattr(id, "name") or ""
end
local function groups_in_line(row)
  local out = {}
  local text = lines[row] or ""
  for col = 0, math.max(0, #text - 1) do
    local name = groups_at(row, col)
    if name ~= "" then
      out[name] = true
    end
  end
  return out
end

local prose = groups_in_line(2)
assert(prose.markdownBold, "bold not highlighted in prose")
assert(prose.markdownCode, "inline code not highlighted in prose")
assert(prose.markdownLinkText or prose.markdownUrl, "link not highlighted in prose")

local removed, added = groups_in_line(6), groups_in_line(7)
assert(removed.diffRemoved, "```diff removed line not coloured as diffRemoved")
assert(added.diffAdded, "```diff added line not coloured as diffAdded")

local lua = groups_in_line(10)
assert(lua.luaStatement or lua.luaNumber or lua.luaComment, "```lua body not coloured by lua syntax")

print("OK highlight")
