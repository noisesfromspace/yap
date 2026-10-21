-- Markdown colouring policy for yap session buffers: Vim's own
-- `syntax/markdown.vim`, not the tree-sitter highlighter.
--
-- The highlighter is not viewport-bounded on these buffers. Its per-redraw
-- parse range is line('w0')..line('w$') — *buffer* rows, not screen rows — so
-- with folds closed a 34-row window spans thousands of rows and the markdown
-- query is iterated over all of them on every redraw. Measured on a 10.8k-line
-- transcript with folds closed: 6.9k-row span, ~8.6k captures, 7-23 ms per
-- redraw, growing with session size. Holding j/k at key-repeat rate then
-- overruns the ~33 ms budget and the input queue backs up (tapping is fine,
-- holding stalls, and crossing a fold is a bigger jump). That is why trimming
-- injections — one tree per inline span, then one per fence, then html —
-- never fixed it: those shrink the tree count, not the row span.
--
-- Vim's syntax engine only evaluates displayed lines, so it is flat in session
-- size, and it already covers what a transcript needs: inline emphasis
-- (bold/italic/code/links) plus embedded fence languages via
-- `g:markdown_fenced_languages`. tree-sitter is still *started* (touchup
-- renders its block decorations from the parser); only the highlighter is
-- stopped.
--
-- Stopping the highlighter also means nothing consumes *injected* trees any
-- more, and dropping them makes opening a big session cheaper. touchup parses
-- the whole buffer on its first render, and the default markdown injections
-- make that parse produce one tree per inline span (7,502 at 34.5k lines), one
-- per fence, and — via html — one `comment` tree per `<!-- yap:… -->` marker:
-- 18,005 trees at 34.5k lines, 48,005 at 92k. Dropping them leaves the single
-- main markdown tree. Measured end to end (touchup's first render on a session
-- buffer): 34.5k lines 413 ms -> 313 ms, 92k lines 1,053 ms -> 780 ms.
--
-- What remains is the main markdown tree itself (166 ms at 34.5k lines, 420 ms
-- at 92k), which yap cannot avoid: touchup's block decorations are read from
-- it, and a mid-file range parse still builds the whole document. Nothing
-- visible is lost by the strip: block decorations come from that main tree,
-- and inline emphasis now comes from `syntax=markdown`, not from the dropped
-- `markdown_inline` trees.

local M = {}

-- A query with no injection captures: `LanguageTree:_get_injections` returns
-- early when the query has none, so a parse builds the main tree and nothing
-- else. Built once.
local no_injections

--- Stop the tree-sitter highlighter and drop its injections, leaving the plain
--- markdown tree that touchup's block renderers need.
local function strip_injections(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser or not parser._children then
    return
  end
  if not no_injections then
    -- A valid query that captures nothing; a query with zero injection
    -- captures short-circuits injection extraction entirely.
    no_injections = vim.treesitter.query.parse("markdown", "((document) @nothing)")
  end
  parser._injection_query = no_injections
  -- Drop children a parse may already have created, and forget the region the
  -- old query covered, so the next parse starts from nothing.
  parser._children = {}
  parser._processed_injection_region = nil
end

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

--- Colour `buf` with the markdown syntax instead of the tree-sitter
--- highlighter. Idempotent.
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
  -- Stop the highlighter only: the parser stays alive for touchup.
  vim.treesitter.stop(buf)
  strip_injections(buf)
  -- Setting 'syntax' re-sources the file (SynSet clears b:current_syntax), so
  -- this also picks up the fenced-language list above.
  vim.api.nvim_buf_call(buf, function()
    vim.bo.syntax = "markdown"
  end)
end

function M.setup()
  merge_fenced()
end

return M
