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
