-- Inline markdown emphasis renderer. parse_line is the pure matcher (no
-- buffer access) and is exercised unconditionally; the viewport render +
-- code/HTML region skip needs the markdown grammar and is exercised only when
-- a parser is available (the isolated test child normally has none).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local inline = require("harness.session.inline")

local function eq(a, b, label)
  local ja, jb = vim.inspect(a), vim.inspect(b)
  if ja ~= jb then
    error(("%s mismatch:\n  got:      %s\n  expected: %s"):format(label, ja, jb), 0)
  end
end

-- Bold: content coloured, `**` delimiters dimmed.
eq(inline.parse_line("**bold**", false), {
  { s = 3, e = 7, hl = "YapInlineBold" },
  { s = 1, e = 3, hl = "YapInlineDim" },
  { s = 7, e = 9, hl = "YapInlineDim" },
}, "bold")

-- Underscore bold.
eq(inline.parse_line("__bold__", false), {
  { s = 3, e = 7, hl = "YapInlineBold" },
  { s = 1, e = 3, hl = "YapInlineDim" },
  { s = 7, e = 9, hl = "YapInlineDim" },
}, "underscore bold")

-- Inline code.
eq(inline.parse_line("`code`", false), {
  { s = 2, e = 6, hl = "YapInlineCode" },
  { s = 1, e = 2, hl = "YapInlineDim" },
  { s = 6, e = 7, hl = "YapInlineDim" },
}, "code")

-- Italic.
eq(inline.parse_line("*em*", false), {
  { s = 2, e = 4, hl = "YapInlineItalic" },
  { s = 1, e = 2, hl = "YapInlineDim" },
  { s = 4, e = 5, hl = "YapInlineDim" },
}, "italic star")

eq(inline.parse_line("_em_", false), {
  { s = 2, e = 4, hl = "YapInlineItalic" },
  { s = 1, e = 2, hl = "YapInlineDim" },
  { s = 4, e = 5, hl = "YapInlineDim" },
}, "italic underscore")

-- Strikethrough.
eq(inline.parse_line("~~strike~~", false), {
  { s = 3, e = 9, hl = "YapInlineStrike" },
  { s = 1, e = 3, hl = "YapInlineDim" },
  { s = 9, e = 11, hl = "YapInlineDim" },
}, "strike")

-- Link: label + url coloured, punctuation dimmed.
eq(inline.parse_line("[a](u)", false), {
  { s = 2, e = 3, hl = "YapInlineLink" },
  { s = 5, e = 6, hl = "YapInlineUrl" },
  { s = 1, e = 2, hl = "YapInlineDim" },
  { s = 3, e = 4, hl = "YapInlineDim" },
  { s = 4, e = 5, hl = "YapInlineDim" },
  { s = 6, e = 7, hl = "YapInlineDim" },
}, "link")

-- Mixed, in a single line.
eq(inline.parse_line("**bold** and *em*", false), {
  { s = 3, e = 7, hl = "YapInlineBold" },
  { s = 1, e = 3, hl = "YapInlineDim" },
  { s = 7, e = 9, hl = "YapInlineDim" },
  { s = 15, e = 17, hl = "YapInlineItalic" },
  { s = 14, e = 15, hl = "YapInlineDim" },
  { s = 17, e = 18, hl = "YapInlineDim" },
}, "mixed")

-- Intraword and spaced stars are not emphasis.
eq(inline.parse_line("a*b", false), {}, "intraword star")
eq(inline.parse_line("2 * 3", false), {}, "spaced star")
eq(inline.parse_line("foo_bar_baz", false), {}, "snake_case")

-- In a heading, delimiters are not dimmed (touchup's rule), content still
-- coloured.
eq(inline.parse_line("# **bold**", true), {
  { s = 5, e = 9, hl = "YapInlineBold" },
}, "heading bold")

-- A lone unmatched delimiter is left alone (no marks at all).
eq(inline.parse_line("**unclosed", false), {}, "unclosed bold")

print("OK inline parse_line")

-- ---------------------------------------------------------------------------
-- End-to-end: render over a visible buffer and assert code/HTML regions are
-- skipped. Requires the markdown grammar.
-- ---------------------------------------------------------------------------

local ok, _ = pcall(vim.treesitter.get_parser, 1, "markdown")
if ok then
  local api = vim.api
  local buf = api.nvim_create_buf(false, true)
  api.nvim_win_set_buf(0, buf)
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].yap = true
  api.nvim_buf_set_lines(buf, 0, -1, false, {
    "prose with **bold**", -- 0: rendered
    "```lua", -- 1: fence
    'local x = "**not bold**"', -- 2: code content, skipped
    "```", -- 3: fence
    "<!-- yap:thinking", -- 4: html block
    "**not bold**", -- 5: skipped
    "-->", -- 6: html block
  })

  inline.render(buf)
  local ns = api.nvim_get_namespaces()["yap.inline"]
  local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})

  local function rows(list, row)
    local out = {}
    for _, m in ipairs(list) do
      if m[2] == row then
        out[#out + 1] = m
      end
    end
    return out
  end

  assert(#rows(marks, 0) > 0, "prose line got no marks")
  assert(#rows(marks, 2) == 0, "fenced code content was parsed for emphasis")
  assert(#rows(marks, 5) == 0, "html comment block was parsed for emphasis")
  print("OK inline render")
end
