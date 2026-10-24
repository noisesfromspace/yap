-- Markdown colouring policy: a yap session buffer is coloured by Vim's
-- markdown syntax, not the tree-sitter highlighter, and the parser keeps its
-- injections (decoration renderers read the tree, not the highlighter).
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
  "<!-- yap:thinking", -- 12
  "Let me check the diff:", -- 13
  "```diff", -- 14
  "-thinking removed", -- 15
  "+thinking added", -- 16
  "```", -- 17
  "-->", -- 18
  "", -- 19
  "Prose with some_thing and other_things.", -- 20
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
-- Languages the parser builds for this buffer *before* the policy runs. The
-- policy must not change this set: renderers read injected trees, so dropping
-- any of them silently deletes their decorations. Compared as a set so the
-- assertion holds whether or not grammars are installed in this environment.
local baseline_langs = {}
if has_parser then
  vim.treesitter.start(buf, "markdown")
  assert(vim.treesitter.highlighter.active[buf] ~= nil, "highlighter was not started")
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if ok and parser then
    pcall(parser.parse, parser, true)
    parser:for_each_tree(function(_, tree)
      baseline_langs[tree:lang()] = true
    end)
  end
end

highlight.apply(buf)

-- The policy: no highlighter, markdown syntax, parser still alive.
if has_parser then
  assert(vim.treesitter.highlighter.active[buf] == nil, "highlighter still active after apply")
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  assert(ok and parser, "parser must survive apply (touchup renders from it)")
  -- Injections must be untouched. Stopping the highlighter does not make them
  -- redundant: touchup reads the `markdown_inline` child for links/markers and
  -- render-markdown dispatches per injected language. Dropping them cost 25->9
  -- touchup marks and 15->11 render-markdown marks on this shape of buffer.
  -- Compare against the pre-policy set so this holds with or without grammars.
  pcall(parser.parse, parser, true)
  local langs = {}
  parser:for_each_tree(function(_, tree)
    langs[tree:lang()] = true
  end)
  for lang in pairs(baseline_langs) do
    assert(langs[lang], "apply() dropped the " .. lang .. " injection")
  end
end
assert(vim.bo[buf].syntax == "markdown", "syntax not set to markdown, got " .. tostring(vim.bo[buf].syntax))

-- Per-keystroke option hooks are cleared. nvim-treesitter's FileType setup sets
-- `indentexpr` for markdown (it ships an indents query) and insert-mode Enter
-- evaluates it: measured 577 ms for one <CR> on a 64k-line session, because the
-- indent query parses from the top of the buffer. A transcript is not code.
vim.bo[buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
vim.bo[buf].formatexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
highlight.apply(buf)
assert(vim.bo[buf].indentexpr == "", "indentexpr not cleared: " .. vim.bo[buf].indentexpr)
assert(vim.bo[buf].formatexpr == "", "formatexpr not cleared: " .. vim.bo[buf].formatexpr)

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

-- The model's reasoning is written as an HTML comment, and html.vim's comment
-- region allows nothing inside it, so a fence in the reasoning used to render
-- as flat comment text. yap's own region re-opens the fences: same dim body,
-- language colouring inside the fence.
local thinking_body = groups_in_line(13)
assert(thinking_body.markdownYapComment, "thinking body is not the yap comment region: " .. vim.inspect(thinking_body))
local thinking_removed, thinking_added = groups_in_line(15), groups_in_line(16)
assert(thinking_removed.diffRemoved, "```diff inside a thinking block lost diffRemoved")
assert(thinking_added.diffAdded, "```diff inside a thinking block lost diffAdded")

-- `markdownError` marks `_` between word characters: CommonMark forbids an
-- underscore emphasis marker inside a word, and Vim paints that as `Error`,
-- background included. `snake_case` is not a mistake in a transcript.
local prose_groups = groups_in_line(20)
assert(not prose_groups.markdownError, "snake_case still flagged as markdownError")

-- The syntax engine assigns its own group names, but Vim's markdown.vim
-- borrows its colours from syntax/html.vim and never links some groups at all,
-- so under a colourscheme that styles only the tree-sitter captures (mini.base16
-- — the modern norm) those constructs rendered plain. Each syntax group is
-- merged with the capture describing the same construct, so the invariant is:
-- every attribute the capture defines must also appear on the syntax group.
local function attrs(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

-- A colourscheme that styles only the captures, the case that broke.
local scheme = {
  { "@markup.strong", { bold = true } },
  { "@markup.italic", { italic = true } },
  { "@markup.strikethrough", { strikethrough = true } },
  { "@markup.raw", { fg = "#123456" } },
  { "@markup.quote", { italic = true } },
  { "@markup.list", { fg = "#654321" } },
  { "@markup.heading.1", { fg = "#abcdef" } },
}
for _, entry in ipairs(scheme) do
  vim.api.nvim_set_hl(0, entry[1], entry[2])
end
vim.cmd("hi clear")
for _, entry in ipairs(scheme) do
  vim.api.nvim_set_hl(0, entry[1], entry[2])
end
highlight.apply(buf)

local parity = {
  { "markdownBold", "@markup.strong" },
  { "markdownItalic", "@markup.italic" },
  { "markdownStrike", "@markup.strikethrough" },
  { "markdownCode", "@markup.raw" },
  { "markdownCodeBlock", "@markup.raw" },
  { "markdownBlockquote", "@markup.quote" },
  { "markdownListMarker", "@markup.list" },
  { "markdownOrderedListMarker", "@markup.list" },
  { "markdownH1", "@markup.heading.1" },
  { "markdownLinkText", "@markup.link.label" },
}
for _, pair in ipairs(parity) do
  local want, got = attrs(pair[2]), attrs(pair[1])
  for key, value in pairs(want) do
    if key ~= "default" and key ~= "cterm" then
      assert(
        got[key] == value,
        ("%s is missing %s=%s from %s: %s"):format(pair[1], key, tostring(value), pair[2], vim.inspect(got))
      )
    end
  end
end

-- Headings carry touchup's `@markup.heading.N.markdown` attributes, which only
-- the tree-sitter highlighter ever applied; `# @user` keeps its underline.
local h1, h2 = attrs("markdownH1"), attrs("markdownH2")
assert(h1.underline, "H1 heading lost its underline")
assert(h1.bold, "H1 heading lost its bold")
assert(h2.underline, "H2 heading lost its underline")

-- Re-applying is a no-op and re-merges after a colourscheme reset.
vim.cmd("hi clear")
vim.api.nvim_set_hl(0, "@markup.raw", { fg = "#123456" })
highlight.apply(buf)
assert(attrs("markdownCode").fg == tonumber("123456", 16), "merge did not survive hi clear")

-- A long fence must keep its language colouring even when the syntax engine
-- syncs from mid-fence. Vim's default markdown sync (minlines=50) cannot reach
-- a fence opener a few hundred lines back, so the body went plain until the
-- viewport scrolled back to the opener — the intermittent "fence went plain"
-- behaviour. `syntax sync fromstart` fixes it. Access the interior out of
-- order so it is hit cold, as a fold jump or page-down would. The content
-- replaces `buf` (rather than a new buffer) because the embedded suite child
-- leaves a freshly-switched window with a stale w$ and synID returns empty.
local long_lines = { "# @assistant", "", "```diff" }
for i = 1, 1000 do
  if i % 2 == 0 then
    long_lines[#long_lines + 1] = "+added " .. i
  else
    long_lines[#long_lines + 1] = "-removed " .. i
  end
end
long_lines[#long_lines + 1] = "```"
api.nvim_buf_set_lines(buf, 0, -1, false, long_lines)
highlight.apply(buf)
-- Deep rows (well past the ~500-line sync horizon), hit out of order.
for _, row in ipairs({ 600, 900, 700, 4 }) do
  local g = groups_at(row, 3)
  assert(
    g == "diffAdded" or g == "diffRemoved",
    ("long-fence row %d lost its diff colour, got %q"):format(row, g)
  )
end

-- A session buffer whose policy never landed keeps an empty 'syntax' (what a
-- dropped deferred apply leaves behind) and renders the whole transcript
-- plain. Showing such a buffer re-applies the policy.
highlight.setup()
vim.bo[buf].syntax = ""
assert(vim.bo[buf].syntax == "", "precondition: syntax cleared")
vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = buf })
assert(vim.bo[buf].syntax == "markdown", "BufWinEnter did not re-apply the markdown policy")

print("OK highlight")
