-- Markdown colouring policy for yap session buffers: Vim's own
-- `syntax/markdown.vim` for the glyph colours, with the tree-sitter parser
-- left fully intact for decoration renderers (touchup, render-markdown).
--
-- Why not the tree-sitter highlighter: it is not viewport-bounded on these
-- buffers. Its per-redraw parse range is line('w0')..line('w$') — *buffer*
-- rows, not screen rows — so with folds closed a 34-row window spans thousands
-- of rows and the markdown query is iterated over all of them on every redraw.
-- Measured on a 10.8k-line transcript with folds closed: 6.9k-row span, ~8.6k
-- captures, 7-23 ms per redraw, growing with session size. Holding j/k at
-- key-repeat rate then overruns the ~33 ms budget and the input queue backs up
-- (tapping is fine, holding stalls, and crossing a fold is a bigger jump). That
-- is why trimming injections — one tree per inline span, then one per fence,
-- then html — never fixed it: those shrink the tree count, not the row span.
--
-- Vim's syntax engine only evaluates displayed lines, so it is flat in session
-- size, and it covers what the transcript needs: inline emphasis
-- (bold/italic/code/links) plus embedded fence languages via
-- `g:markdown_fenced_languages`. Only the *highlighter* is stopped; the parser
-- keeps running.
--
-- Why the injections stay: decoration renderers are consumers of the parsed
-- tree, not of the highlighter, so stopping the highlighter does not make them
-- redundant. touchup reads the main markdown tree for its block renderers
-- (headings, fences, quotes, bullets, checkboxes) and the `markdown_inline`
-- child for link/marker styling; render-markdown dispatches handlers per
-- injected language (`markdown`, `markdown_inline`, `html`, `yaml`, `latex`).
-- Dropping injections to speed up first render was measured at 25 -> 9 touchup
-- marks and 15 -> 11 render-markdown marks on the same buffer, so it is not
-- worth the saving: it silently deletes most of the visible decoration.
--
-- What that leaves is an open-time cost rather than a scroll cost: a renderer
-- parses the whole buffer synchronously on its first render (166 ms at 34.5k
-- lines, 420 ms at 92k for the main tree alone). That belongs to the renderer
-- — Neovim time-slices the same parse when a callback is passed — and is not
-- something this module can remove without breaking the renderers themselves.

local M = {}

-- Fence languages that get embedded syntax colouring. These all ship with
-- Neovim; a fence tagged with anything else renders as plain code.
local fenced = { "bash", "diff", "json", "lua", "python", "toml", "vim", "yaml" }

--- `g:markdown_fenced_languages` is global — `syntax/markdown.vim` reads it
--- while sourcing, per buffer — so extend whatever the user set rather than
--- replacing it.
local function merge_fenced()
  local list = vim.deepcopy(vim.g.markdown_fenced_languages or {})
  local seen = {}
  for _, lang in ipairs(list) do
    seen[lang] = true
  end
  for _, lang in ipairs(fenced) do
    if not seen[lang] then
      list[#list + 1] = lang
      seen[lang] = true
    end
  end
  vim.g.markdown_fenced_languages = list
end

-- Vim's `syntax/markdown.vim` borrows its colours from `syntax/html.vim`
-- (`markdownBold -> htmlBold`, `markdownH1 -> htmlH1`, ...) and leaves some
-- groups unlinked altogether (`markdownCode`, `markdownCodeBlock`). A
-- colourscheme built for tree-sitter — mini.base16, the modern default — styles
-- the `@markup.*` captures and no HTML groups, so those chains dead-end at an
-- undefined group and the text renders plain. Link the intermediates to the
-- captures the colourscheme does style, so syntax=markdown looks like the
-- tree-sitter highlighting it replaced.
--
-- `default = true` throughout: a colourscheme that styles these legacy groups,
-- or the syntax file's own link, always wins — this only fills the holes.
local legacy_links = {
  -- intermediates syntax/markdown.vim links through
  { "htmlBold", "@markup.strong" },
  { "htmlBoldItalic", "@markup.strong" },
  { "htmlItalic", "@markup.italic" },
  { "htmlStrike", "@markup.strikethrough" },
  { "htmlCode", "@markup.raw" },
  { "htmlLink", "@markup.link.label" },
  { "htmlTag", "@tag" },
  { "htmlTagName", "@tag" },
  { "htmlSpecialChar", "@string.escape" },
  -- groups syntax/markdown.vim never links
  { "markdownCode", "@markup.raw" },
  { "markdownCodeBlock", "@markup.raw" },
  { "markdownCodeDelimiter", "@punctuation.special" },
  { "markdownLinkDelimiter", "@punctuation.special" },
  { "markdownLinkTextDelimiter", "@punctuation.special" },
  { "markdownListMarker", "@markup.list" },
  { "markdownOrderedListMarker", "@markup.list" },
  { "markdownBlockquote", "@markup.quote" },
  { "markdownRule", "@punctuation.special" },
}
for i = 1, 6 do
  legacy_links[#legacy_links + 1] = { "htmlH" .. i, "@markup.heading." .. i }
  legacy_links[#legacy_links + 1] = { "markdownH" .. i, "@markup.heading." .. i }
end

--- Fill the gaps in the legacy markdown colour chains. Idempotent, and must
--- run after `syntax/markdown.vim` is sourced so its own links win.
local function link_legacy()
  for _, pair in ipairs(legacy_links) do
    vim.api.nvim_set_hl(0, pair[1], { link = pair[2], default = true })
  end
end

--- Colour `buf` with the markdown syntax instead of the tree-sitter
--- highlighter, leaving the parser (and its injections) for the decoration
--- renderers. Idempotent.
function M.apply(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- `syntax/markdown.vim` reads this while sourcing, so set it first.
  merge_fenced()
  -- The Syntax autocommand lives in synload.vim, which `:syntax enable`
  -- sources. Mirror the highlighter's own fallback (a plugin must not turn
  -- syntax on globally) so the groups exist either way. `syntaxset` may then
  -- be missing while g:syntax_on is set, so create it as core does.
  if vim.g.syntax_on ~= 1 then
    vim.cmd.runtime({ "syntax/synload.vim", bang = true })
    vim.api.nvim_create_augroup("syntaxset", { clear = false })
  end
  -- Stop the highlighter only: the parser and its injections stay alive for
  -- the decoration renderers, which read the tree directly.
  vim.treesitter.stop(buf)
  -- Setting 'syntax' re-sources the file (SynSet clears b:current_syntax), so
  -- this also picks up the fenced-language list above.
  vim.api.nvim_buf_call(buf, function()
    vim.bo.syntax = "markdown"
  end)
  -- After the syntax file: its links are in place, so ours only fill gaps.
  link_legacy()
end

function M.setup()
  merge_fenced()
end

return M
