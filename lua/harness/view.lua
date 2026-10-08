-- Shared presentation primitives for Yap's read-only "board" buffers: the
-- guard board (yap://guard), the audit view (yap://<session>-audit), and any
-- future projection. Both are rebuilt-from-events buffers opened as a bottom
-- drawer with a two-line header (title + counts), linked highlight groups,
-- and manual folds. New views reuse these so they look and behave alike;
-- view-specific highlight groups stay in the view's own module.

local M = {}

-- Common highlight groups: the header title and its counts line.
M.hl = {
  header = "YapViewHeader",
  meta = "YapViewMeta",
}

--- Register a linked highlight group. `link = to` (not a fixed color) keeps
--- every colorscheme working; `default = true` keeps user overrides.
function M.link(name, to)
  vim.api.nvim_set_hl(0, name, { link = to, default = true })
end

M.link(M.hl.header, "Title")
M.link(M.hl.meta, "Comment")

--- Flatten embedded newlines in a free-text field into spaces, so one logical
--- field can never inject extra buffer lines.
function M.flat(s)
  return (s or ""):gsub("[\r\n]+", " ")
end

--- Truncate `s` to at most `n` characters, appending an ellipsis when cut.
function M.clip(s, n)
  s = M.flat(s)
  if #s > n then
    return s:sub(1, n - 1) .. "…"
  end
  return s
end

--- Pad or truncate `s` to a fixed `width` so columns align (no ellipsis).
function M.cell(s, width)
  s = s or ""
  if #s > width then
    s = s:sub(1, width)
  end
  return s .. string.rep(" ", width - #s)
end

--- The two header lines shared by every view: a title and a counts summary.
--- Highlight line 1 with M.hl.header and line 2 with M.hl.meta.
function M.header_lines(title, counts)
  return { title, ("  " .. counts) }
end

return M
