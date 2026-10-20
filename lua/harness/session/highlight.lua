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
-- viewport-bounded, so it stays cheap. This module drops just the
-- `markdown_inline` injection when the policy says so — `syntax_highlight =
-- "block"`, or full mode past `syntax_highlight_block_lines` lines — keeping
-- the cheap block colours. There is no public Neovim API to change injections
-- after a parser exists, so it swaps the LanguageTree's injection query and
-- removes the inline child directly (fields stable since Neovim 0.5).

local M = {}

local function harness()
  return require("harness")
end

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

local function block_query_obj()
  if not block_query then
    block_query = vim.treesitter.query.parse("markdown", block_injections)
  end
  return block_query
end

--- The highlight mode this buffer should currently be in: "none", "block",
--- or "full". Resolved from the `syntax_highlight` config and the live line
--- count (full auto-downgrades to block past the configured threshold).
function M.mode(buf)
  local want = harness().config.syntax_highlight
  if want == false then
    return "none"
  end
  if want == "block" then
    return "block"
  end
  local limit = harness().config.syntax_highlight_block_lines or 0
  if limit > 0 and vim.api.nvim_buf_line_count(buf) > limit then
    return "block"
  end
  return "full"
end

-- Drop the inline child and re-point the injection query so future parses do
-- not re-create it. The child removal is picked up on the next redraw; no
-- reparse is needed because block-level highlighting lives in the main tree.
local function drop_inline(buf)
  local parser = vim.treesitter.get_parser(buf, "markdown")
  if not parser or not parser._children then
    return
  end
  parser._injection_query = block_query_obj()
  parser._children.markdown_inline = nil
end

-- Undo drop_inline: restore the default injections and force a reparse so
-- markdown_inline children are recreated. Only happens when a session shrinks
-- back under the threshold (e.g. after :YapCompact).
local function restore_inline(buf)
  local parser = vim.treesitter.get_parser(buf, "markdown")
  if not parser or not parser._children then
    return
  end
  parser._injection_query = vim.treesitter.query.get("markdown", "injections")
  parser:invalidate(true)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(parser.parse, parser)
    end
  end)
end

--- Bring the buffer to its configured highlight mode. A no-op when it is
--- already there, so it is safe to call on every append.
function M.apply(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local prev = vim.b[buf].yap_highlight_mode
  local mode = M.mode(buf)
  if prev == mode then
    return
  end
  vim.b[buf].yap_highlight_mode = mode
  if mode == "none" then
    local hl = vim.treesitter.highlighter and vim.treesitter.highlighter.active[buf]
    if hl and hl.destroy then
      hl:destroy()
    end
  elseif mode == "block" then
    drop_inline(buf)
  elseif prev == "block" then
    -- Only an explicit downgrade-then-shrink restores inline; a fresh buffer
    -- already defaults to full and must not be invalidated/reparsed.
    restore_inline(buf)
  end
end

return M
