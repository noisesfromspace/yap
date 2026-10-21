-- Treesitter highlight policy for yap buffers.
--
-- The full markdown highlighter is O(buffer) per scroll, not O(viewport): the
-- markdown grammar injects `markdown_inline` once per inline span (every
-- **bold**, `code`, *em*, [link]), one tree per span across the whole buffer,
-- and the highlighter walks every one of them on each viewport change. On a
-- long transcript that is the jitter people feel holding j/k — not touchup,
-- which renders from its own viewport cache.
--
-- Block-level highlighting (headings, fences, quotes, lists, and the
-- syntax-coloured code inside fences) lives in the main tree and is
-- viewport-bounded, so it stays cheap. Yap therefore always drops the
-- `markdown_inline` injection, keeping the cheap block colours. Inline
-- emphasis is restored separately by harness.session.inline (a
-- viewport-bounded regex renderer). There is no public Neovim API to change
-- injections after a parser exists, so it swaps the LanguageTree's injection
-- query and removes the inline child directly (fields stable since Neovim
-- 0.5).

local M = {}

-- The runtime markdown injections query with the per-span
-- `(inline) / (pipe_table_cell) -> markdown_inline` injection removed.
-- Everything else (fenced code, html, yaml/toml frontmatter) is kept, so
-- fenced code still gets its own language's token colours.
local block_injections = [==[
(fenced_code_block
  (info_string
    (language) @injection.language)
  (code_fence_content) @injection.content)

((html_block) @injection.content
  (#set! injection.language "html")
  (#set! injection.combined)
  (#set! injection.include-children))

((minus_metadata) @injection.content
  (#set! injection.language "yaml")
  (#offset! @injection.content 1 0 -1 0)
  (#set! injection.include-children))

((plus_metadata) @injection.content
  (#set! injection.language "toml")
  (#offset! @injection.content 1 0 -1 0)
  (#set! injection.include-children))
]==]

local block_query

--- Drop the inline child and re-point the injection query so future parses do
--- not re-create it. The child removal is picked up on the next redraw; no
--- reparse is needed because block-level highlighting lives in the main tree.
function M.apply(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local parser = vim.treesitter.get_parser(buf, "markdown")
  if not parser or not parser._children then
    return
  end
  if not block_query then
    block_query = vim.treesitter.query.parse("markdown", block_injections)
  end
  parser._injection_query = block_query
  parser._children.markdown_inline = nil
end

return M
