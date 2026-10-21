-- Treesitter highlight policy for yap buffers.
--
-- The full markdown highlighter is O(buffer) per scroll, not O(viewport): the
-- markdown grammar injects `markdown_inline` once per inline span (every
-- **bold**, `code`, *em*, [link]), one tree per span across the whole buffer,
-- and the highlighter walks every one of them on each viewport change. On a
-- long transcript that is the jitter people feel holding j/k — not touchup,
-- which renders from its own viewport cache.
--
-- Block-level highlighting (headings, quotes, lists) lives in the main tree;
-- fenced-code token colours come from a combined per-language injection (one
-- tree per language, not per fence), and inline emphasis is restored
-- separately by harness.session.inline (a viewport-bounded regex renderer).
-- Both stay cheap: the main tree is viewport-bounded and the combined
-- injection collapses to a handful of trees, so the per-scroll
-- for_each_tree walk is O(1) in the number of fences. There is no public
-- Neovim API to change injections after a parser exists, so it swaps the
-- LanguageTree's injection query and removes the inline child directly
-- (fields stable since Neovim 0.5).
--
-- HTML blocks are deliberately not injected either. In a yap session the HTML
-- blocks are the `<!-- yap:tool -->` / `<!-- yap:thinking -->` markers: one or
-- two per tool call. Injecting them costs a tree per marker on top of an html
-- child that injects a `comment` tree per HTML comment, so a 4k-message
-- session ended up with ~16k injected trees, and every viewport change walked
-- all of them (2.2ms per redraw at 28k lines, growing linearly). Since the
-- markers are rendered by touchup (comment-block labels) and carry no
-- highlight capture of their own, dropping the injection costs nothing and
-- keeps the tree count constant. Raw HTML the model writes into prose is
-- shown as plain text rather than token-coloured.

local M = {}

-- The runtime markdown injections query with the per-span
-- `(inline) / (pipe_table_cell) -> markdown_inline` injection removed, the
-- fenced-code injection marked `combined`, and the html_block injection
-- dropped. Without `combined`, each fence is its own injected tree, and the
-- highlighter re-walks every injected tree on every viewport change
-- (O(#fences) per scroll); `combined` collapses all fences of a language into
-- one tree (the same mechanism the upstream grammar already uses for HTML
-- blocks), so scrolling is O(viewport) again. Fenced code still gets its own
-- language's token colours. HTML is dropped for the reason above: in a yap
-- session its blocks are the yap markers, and it spawns a `comment` tree per
-- comment — O(#tool calls) trees walked per redraw.
local block_injections = [==[
((fenced_code_block
  (info_string
    (language) @injection.language)
  (code_fence_content) @injection.content)
  (#set! injection.combined))

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
