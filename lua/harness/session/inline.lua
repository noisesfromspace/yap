-- Inline markdown emphasis for yap buffers, rendered viewport-bounded.
--
-- The full markdown treesitter highlighter is O(buffer) per scroll: the
-- markdown grammar injects `markdown_inline` once per inline span (every
-- **bold**, `code`, *em*, [link]) — one tree per span across the whole
-- buffer — and the highlighter walks every one of them on each viewport
-- change. Yap drops that injection (highlight.lua) so the block-level
-- highlighter stays cheap, which also disables inline colouring.
--
-- This module restores the inline emphasis that lived in the dropped
-- injection with a regex pass over the visible lines only. It is O(viewport)
-- per scroll and persistent-cached per (changedtick, viewport) exactly like
-- touchup, so a long transcript never re-walks itself. The block-level
-- markdown tree is used only to classify each visible line as prose versus
-- code/HTML: fenced code, indented code and the yap comment blocks
-- (thinking/tool markers, which are `html_block` nodes) get no inline
-- parsing, so a stray `**` inside ```diff/```lua never corrupts its syntax
-- colours.
--
-- Regex matching is deliberately not CommonMark: nested or pathological
-- emphasis resolves coarsely. That is an accepted trade for viewport-bounded
-- cost — transcripts are prose, not adversarial markdown.
--
-- This renderer is fully self-contained and does not intervene with other
-- markdown renderers (touchup, render-markdown): it owns its own namespace
-- (`yap.inline`), its own highlight groups (`YapInline*`, defined with
-- `default = true` so nothing else is overridden), and its own decoration
-- provider. It is inert on non-yap buffers — `on_win` returns unless
-- `vim.b[bufnr].yap` — so ordinary markdown files are untouched. It also
-- never restores or touches the `markdown_inline` injection that
-- highlight.lua removes. Caveat: if that injection is ever re-enabled on a
-- yap buffer (e.g. by a plugin calling `vim.treesitter.query.set`), both this
-- pass and the treesitter highlighter would colour the same spans; the
-- injection is removed once at setup and never restored, so that cannot
-- happen in the current flow.

local M = {}

local api = vim.api

local NAMESPACE = api.nvim_create_namespace("yap.inline")
local GROUP = api.nvim_create_augroup("YapInline", { clear = true })

-- Highlight groups linked to the standard treesitter markup groups the
-- dropped injection would have used, so colours follow the active theme.
local HL_DEFS = {
  { "YapInlineCode", "@markup.raw" },
  { "YapInlineBold", "@markup.strong" },
  { "YapInlineItalic", "@markup.italic" },
  { "YapInlineStrike", "@markup.strikethrough" },
  { "YapInlineLink", "@markup.link.label" },
  { "YapInlineUrl", "@markup.link.url" },
  { "YapInlineDim", "NonText" },
}

-- bufnr -> { tick, top, bot, pending }
local rendered = {}

-- Extra lines rendered above/below the viewport so a small scroll is already
-- covered and does not re-render.
local RENDER_MARGIN = 20

local function define_hl()
  for _, def in ipairs(HL_DEFS) do
    api.nvim_set_hl(0, def[1], { link = def[2], default = true })
  end
end

--- Count the run of `ch` starting at 1-based position i (inclusive).
local function count_run(s, i, ch)
  local n = 0
  while s:sub(i + n, i + n) == ch do
    n = n + 1
  end
  return n
end

--- Find a run of exactly `n` of `ch` at or after `from` (1-based), or nil.
local function find_run(s, ch, n, from)
  local i = from
  while i <= #s do
    if s:sub(i, i) == ch then
      local cnt = count_run(s, i, ch)
      if cnt == n then
        return i
      end
      i = i + cnt
    else
      i = i + 1
    end
  end
  return nil
end

local function is_word(c)
  return c ~= "" and c:match("%w") ~= nil
end

-- An emphasis opener: `ch` must not sit inside a word and must be followed by
-- a non-space (rejects `a*b`, `foo_bar` and `2 * 3`).
local function can_open(s, i)
  local prev = s:sub(i - 1, i - 1)
  local nxt = s:sub(i + 1, i + 1)
  if nxt == "" or nxt == " " or nxt == "\t" then
    return false
  end
  if i > 1 and is_word(prev) then
    return false
  end
  return true
end

local function can_close(s, i)
  local prev = s:sub(i - 1, i - 1)
  local nxt = s:sub(i + 1, i + 1)
  if prev == "" or prev == " " or prev == "\t" then
    return false
  end
  if i < #s and is_word(nxt) then
    return false
  end
  return true
end

--- Find a closing single `ch` (not part of a longer run) that satisfies
--- can_close, at or after `from`.
local function find_italic_close(s, ch, from)
  local i = from
  while i <= #s do
    if s:sub(i, i) == ch then
      local cnt = count_run(s, i, ch)
      if cnt == 1 and can_close(s, i) then
        return i
      end
      i = i + cnt
    else
      i = i + 1
    end
  end
  return nil
end

--- Parse one line's inline emphasis into marks. Pure (no buffer access);
--- exposed for testing. Each mark is { s, e, hl } with 1-based byte offsets,
--- s inclusive and e exclusive.
---@param text string
---@param in_heading boolean when true (line is inside a heading) delimiters
--- are not dimmed, matching touchup's heading treatment.
---@return table[] marks
function M.parse_line(text, in_heading)
  local marks = {}
  local dim = not in_heading
  local function add(s, e, hl)
    if e > s then
      marks[#marks + 1] = { s = s, e = e, hl = hl }
    end
  end

  local n = #text
  local i = 1
  while i <= n do
    local c = text:sub(i, i)
    if c == "`" then
      local run = count_run(text, i, "`")
      if run > 3 then
        run = 3
      end
      local close = find_run(text, "`", run, i + run)
      if close then
        add(i + run, close, "YapInlineCode")
        if dim then
          add(i, i + run, "YapInlineDim")
          add(close, close + run, "YapInlineDim")
        end
        i = close + run
      else
        i = i + 1
      end
    elseif c == "!" and text:sub(i, i + 1) == "![" then
      if dim then
        add(i, i + 1, "YapInlineDim")
      end
      i = i + 1
    elseif c == "[" then
      local s, e, label, url = text:find("%[(.-)%]%((.-)%)", i)
      if s then
        add(s + 1, s + 1 + #label, "YapInlineLink")
        add(s + 3 + #label, s + 3 + #label + #url, "YapInlineUrl")
        if dim then
          add(s, s + 1, "YapInlineDim") -- [
          add(s + 1 + #label, s + 2 + #label, "YapInlineDim") -- ]
          add(s + 2 + #label, s + 3 + #label, "YapInlineDim") -- (
          add(e, e + 1, "YapInlineDim") -- )
        end
        i = e + 1
      else
        i = i + 1
      end
    elseif c == "~" and text:sub(i, i + 1) == "~~" then
      local close = text:find("~~", i + 2, true)
      if close then
        add(i + 2, close, "YapInlineStrike")
        if dim then
          add(i, i + 2, "YapInlineDim")
          add(close, close + 2, "YapInlineDim")
        end
        i = close + 2
      else
        i = i + 1
      end
    elseif c == "*" then
      if text:sub(i, i + 1) == "**" then
        local close = text:find("**", i + 2, true)
        if close then
          add(i + 2, close, "YapInlineBold")
          if dim then
            add(i, i + 2, "YapInlineDim")
            add(close, close + 2, "YapInlineDim")
          end
          i = close + 2
        else
          i = i + 1
        end
      elseif can_open(text, i) then
        local close = find_italic_close(text, "*", i + 1)
        if close then
          add(i + 1, close, "YapInlineItalic")
          if dim then
            add(i, i + 1, "YapInlineDim")
            add(close, close + 1, "YapInlineDim")
          end
          i = close + 1
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    elseif c == "_" then
      if text:sub(i, i + 1) == "__" then
        local close = text:find("__", i + 2, true)
        if close then
          add(i + 2, close, "YapInlineBold")
          if dim then
            add(i, i + 2, "YapInlineDim")
            add(close, close + 2, "YapInlineDim")
          end
          i = close + 2
        else
          i = i + 1
        end
      elseif can_open(text, i) then
        local close = find_italic_close(text, "_", i + 1)
        if close then
          add(i + 1, close, "YapInlineItalic")
          if dim then
            add(i, i + 1, "YapInlineDim")
            add(close, close + 1, "YapInlineDim")
          end
          i = close + 1
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return marks
end

-- Block nodes whose contents get no inline parsing: fenced/indented code and
-- HTML blocks (the yap thinking/tool markers are HTML comments).
local SKIP = {
  fenced_code_block = true,
  code_fence_content = true,
  indented_code_block = true,
  html_block = true,
}

--- Classify a line with the block-level markdown tree.
---@return boolean should_render
---@return boolean in_heading
local function classify(root, buf, row)
  local ok, node = pcall(root.named_descendant_for_range, root, row, 0, row, 0)
  if not ok or not node then
    return true, false
  end
  local in_heading = false
  while node do
    local t = node:type()
    if SKIP[t] then
      return false, false
    end
    if t == "atx_heading" or t == "setext_heading" then
      in_heading = true
    end
    node = node:parent()
  end
  return true, in_heading
end

--- The union of every window's viewport (0-based, inclusive) showing `buf`.
local function viewport(buf)
  local top, bot = math.huge, -1
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
      local info = vim.fn.getwininfo(win)[1] or {}
      local t = (info.topline or 1) - 1
      local b = (info.botline or 1) - 1
      top = math.min(top, t)
      bot = math.max(bot, b)
    end
  end
  if top == math.huge then
    return nil
  end
  return top, bot
end

--- Render [viewport ± margin] into persistent extmarks, after clearing the
--- namespace. Runs from a scheduled callback, never inline in on_win.
function M.render(buf)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local st = rendered[buf]
  if not st then
    st = { tick = -1, top = 0, bot = 0 }
    rendered[buf] = st
  end
  local top, bot = viewport(buf)
  if not top then
    api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)
    rendered[buf] = nil
    return
  end
  top = math.max(0, top - RENDER_MARGIN)
  bot = bot + RENDER_MARGIN
  local tick = api.nvim_buf_get_changedtick(buf)

  api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)

  -- get_parser throws when the markdown grammar is not installed; the
  -- block-level highlighter is unavailable then too, so nothing to do.
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  local root
  if ok and parser then
    local trees = parser:parse()
    root = trees[1] and trees[1]:root()
  end
  if not root then
    st.tick, st.top, st.bot = tick, top, bot
    return
  end

  local last = api.nvim_buf_line_count(buf) - 1
  bot = math.min(bot, last)
  for row = top, bot do
    local should, in_heading = classify(root, buf, row)
    if should then
      local text = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
      if #text > 0 then
        for _, m in ipairs(M.parse_line(text, in_heading)) do
          api.nvim_buf_set_extmark(buf, NAMESPACE, row, m.s - 1, {
            end_col = m.e - 1,
            hl_group = m.hl,
            priority = 150,
          })
        end
      end
    end
  end
  st.tick, st.top, st.bot = tick, top, bot
end

local function schedule_render(buf)
  local st = rendered[buf]
  if not st then
    st = { tick = -1, top = 0, bot = 0 }
    rendered[buf] = st
  end
  if st.pending then
    return
  end
  st.pending = true
  vim.schedule(function()
    st.pending = false
    M.render(buf)
  end)
end

function M.setup()
  define_hl()
  api.nvim_create_autocmd("ColorScheme", {
    group = GROUP,
    callback = define_hl,
  })
  api.nvim_create_autocmd("BufDelete", {
    group = GROUP,
    callback = function(args)
      rendered[args.buf] = nil
    end,
  })
  api.nvim_set_decoration_provider(NAMESPACE, {
    on_win = function(_, winid, bufnr, toprow, botrow)
      if not vim.b[bufnr].yap then
        return false
      end
      local tick = api.nvim_buf_get_changedtick(bufnr)
      local st = rendered[bufnr]
      if st and st.tick == tick and toprow >= st.top and botrow <= st.bot then
        return false
      end
      schedule_render(bufnr)
      return false
    end,
  })
end

return M
