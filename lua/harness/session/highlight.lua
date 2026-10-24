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
--
-- Session buffers also drop the per-keystroke option hooks a markdown setup
-- installs. nvim-treesitter's FileType handling sets `indentexpr` for any
-- language with an `indents` query — markdown has one — and Vim evaluates it on
-- every new line (<CR>, `o`, `O`) and on `=`. Its query parses from the top of
-- the buffer, and folds make its `w0..w$` range span thousands of rows, so one
-- <CR> measured 577 ms on a 64k-line session versus 9 ms with the hook cleared.
-- A transcript is not code: plain 'autoindent' is the right behaviour.

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
-- undefined group and the text renders plain.
--
-- `default = true` is not enough here: `syntax/markdown.vim` already links most
-- of these groups, so a default definition is ignored and, for example,
-- `markdownBlockquote` kept `Comment`'s foreground but never picked up
-- `@markup.quote`'s italic. Instead each syntax group is set to the merge of
-- what it resolves to today and the capture that describes the same thing — so
-- the syntax engine ends up with the rendering the tree-sitter highlighter gave
-- the same construct.
--
-- Headings also carry touchup's declarations: it styles the lang-suffixed
-- `@markup.heading.1.markdown` (bold + underline) and `.2` (underline), which
-- only the tree-sitter highlighter ever applied. Those attributes are folded in
-- so `# @user` keeps its underline under the syntax engine.
local capture_map = {
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
  { "markdownStrike", "@markup.strikethrough" },
  { "markdownBold", "@markup.strong" },
  { "markdownItalic", "@markup.italic" },
  { "markdownLinkText", "@markup.link.label" },
  { "markdownUrl", "@markup.link.url" },
  -- the html intermediates syntax/markdown.vim links through
  { "htmlBold", "@markup.strong" },
  { "htmlBoldItalic", "@markup.strong" },
  { "htmlItalic", "@markup.italic" },
  { "htmlStrike", "@markup.strikethrough" },
  { "htmlCode", "@markup.raw" },
  { "htmlLink", "@markup.link.label" },
  { "htmlTag", "@tag" },
  { "htmlTagName", "@tag" },
  { "htmlSpecialChar", "@string.escape" },
}

-- What touchup declares for `@markup.heading.N.markdown`, per level.
local heading_extra = {
  [1] = { bold = true, underline = true },
  [2] = { underline = true },
}

-- Heading groups get the capture plus touchup's attributes; the intermediates
-- and the syntax groups are both set so either lookup path lands the same way.
for i = 1, 6 do
  local extra = heading_extra[i] or {}
  capture_map[#capture_map + 1] = { "htmlH" .. i, "@markup.heading." .. i, extra }
  capture_map[#capture_map + 1] = { "markdownH" .. i, "@markup.heading." .. i, extra }
end

--- Attributes of a group with its link chain already followed.
local function resolved(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false }) or {}
end

--- Fenced blocks inside a thinking block. The model's reasoning is written as
--- an HTML comment (`<!-- yap:thinking` … `-->`), and html.vim's comment region
--- allows nothing but @Spell inside it, so a fence in the reasoning rendered as
--- flat comment text. The colours only ever appeared by accident: when Vim's
--- syntax sync started *below* the comment opener it never entered the comment,
--- so the fence matched as a top level region instead — the same block was
--- coloured or not depending on where the viewport happened to be.
---
--- yap owns this markup, so it can re-open the fences: the thinking comment gets
--- a region of its own, defined after html.vim's and at the same position (so it
--- wins on the opener line), that allows the fenced-code regions markdown.vim
--- built from `g:markdown_fenced_languages`. The body keeps 'Comment' from the
--- region's own highlight; only the fences inside it are recoloured.
local function fence_contains()
  -- Entries are `lang` or `file=lang` and markdown.vim names the region after
  -- the right-hand side, without any `.suffix`.
  local names = { "markdownCodeBlock" }
  for _, spec in ipairs(vim.g.markdown_fenced_languages or {}) do
    local lang = (spec:match("[^=]*$") or spec):match("^[^.]*")
    if lang and lang ~= "" then
      names[#names + 1] = "markdownHighlight_" .. lang
    end
  end
  return table.concat(names, ",")
end

--- Syntax items yap adds on top of `syntax/markdown.vim`. Buffer-local, so it
--- must run inside `nvim_buf_call`.
local function define_regions()
  vim.cmd(
    "silent! syntax region markdownYapComment matchgroup=Comment"
      .. " start=+^<!-- yap:thinking\\s*$+ end=+^-->\\s*$+ keepend contains="
      .. fence_contains()
  )
  -- Vim marks `_` between word characters (`some_thing`) as a markdown error:
  -- in CommonMark an underscore inside a word cannot open emphasis, and the
  -- syntax file paints that as `Error`, background included. A transcript is
  -- full of snake_case identifiers and none of them are mistakes.
  vim.cmd("silent! syntax clear markdownError")
end

--- Merge each syntax group with the capture that describes the same construct.
--- `nvim_get_hl` already resolved the chain, so a colourscheme's own styling of
--- the syntax group survives; the capture only overrides what it defines.
local function apply_captures()
  -- The thinking region's own group (see define_regions) mirrors the html
  -- comment it replaces. Set here rather than linked once, because a
  -- colourscheme change clears user-defined highlights.
  vim.api.nvim_set_hl(0, "markdownYapComment", { link = "Comment" })
  for _, entry in ipairs(capture_map) do
    local group, capture, extra = entry[1], entry[2], entry[3]
    local attrs = resolved(group)
    for k, v in pairs(resolved(capture)) do
      attrs[k] = v
    end
    for k, v in pairs(extra or {}) do
      attrs[k] = v
    end
    attrs.default = nil
    vim.api.nvim_set_hl(0, group, attrs)
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
  -- A tree-sitter-driven option hook re-parses the buffer on every keystroke.
  -- nvim-treesitter's FileType setup sets `indentexpr` for markdown (it ships an
  -- indents query), and insert-mode Enter evaluates it for the new line: 170-500
  -- ms per Enter on a 64k-line session, because the indent query parses from the
  -- top of the buffer and folds make its `w0..w$` range span thousands of rows.
  -- A transcript is not code — plain 'autoindent' is the right behaviour, and
  -- nothing else in yap sets these.
  vim.bo[buf].indentexpr = ""
  vim.bo[buf].formatexpr = ""
  -- Setting 'syntax' re-sources the file (SynSet clears b:current_syntax), so
  -- this also picks up the fenced-language list above.
  vim.api.nvim_buf_call(buf, function()
    vim.bo.syntax = "markdown"
    define_regions()
    -- markdown.vim's default sync (`syn sync minlines=50` + `linebreaks=1`)
    -- cannot see a fence opener more than ~500 lines above the line being
    -- synced, so a long fence body re-synced mid-fence loses its language
    -- colouring until the viewport scrolls back near the opener. That is the
    -- intermittent "fence went plain" behaviour. Parse from the top instead:
    -- Vim caches per-line syntax state, so this costs only the first paint of
    -- a row (~0.04 ms/line worst case, measured on an injected language), not
    -- every redraw — the per-redraw cost is what this whole policy exists to
    -- avoid in the tree-sitter highlighter.
    vim.cmd("syntax sync fromstart")
  end)
  -- After the syntax file: its links are in place, so the merge starts from them.
  apply_captures()
  -- Record that the policy landed. BufWinEnter heals against this flag rather
  -- than the 'syntax' option string, which stays "markdown" even after a
  -- plugin re-sources the file and wipes yap's own regions.
  vim.b[buf].yap_colour = true
end

local group = vim.api.nvim_create_augroup("YapMarkdownColour", { clear = true })

function M.setup()
  merge_fenced()
  -- The merged groups are set explicitly (not `default`), so a colourscheme
  -- change wipes them; re-merge against the new scheme.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      if vim.g.syntax_on == 1 then
        apply_captures()
      end
    end,
  })
  -- Self-heal a session buffer whose policy never landed, or whose yap
  -- regions were wiped by a re-source that left the 'syntax' option at
  -- "markdown". setup_buffer applies the policy from a vim.schedule callback;
  -- when that callback is dropped (the buffer was not displayed yet, or it
  -- raised) the buffer keeps an empty 'syntax', so the whole transcript — and
  -- every decoration that depends on the syntax groups — renders plain.
  -- Re-apply when such a buffer is shown.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      local buf = tonumber(args.buf)
      if buf and vim.b[buf].yap and (not vim.b[buf].yap_colour or vim.bo[buf].syntax ~= "markdown") then
        M.apply(buf)
      end
    end,
  })
  -- A re-source of the markdown syntax file (setting 'syntax', `:syntax on`,
  -- another plugin forcing the filetype again) drops yap's own regions while
  -- leaving 'syntax' set to "markdown"; the BufWinEnter heal cannot see that
  -- from the option alone. Clear the flag on every re-source so the next
  -- show re-applies.
  vim.api.nvim_create_autocmd("Syntax", {
    group = group,
    callback = function(args)
      local buf = tonumber(args.buf)
      if buf and vim.b[buf].yap then
        vim.b[buf].yap_colour = nil
      end
    end,
  })
  -- A late FileType handler (nvim-treesitter's indents query, another
  -- ftplugin) can re-install the per-keystroke option hooks apply() clears.
  -- Re-apply after those have run. Guarded on yap_colour so the initial
  -- setup path (filetype set before apply) is not applied twice.
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(args)
      local buf = tonumber(args.buf)
      if buf and vim.b[buf].yap and vim.b[buf].yap_colour then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            M.apply(buf)
          end
        end)
      end
    end,
  })
end

return M
