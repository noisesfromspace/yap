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

--- The two header lines shared by every view: a title and a counts summary.
--- Highlight line 1 with M.hl.header and line 2 with M.hl.meta.
function M.header_lines(title, counts)
  return { title, ("  " .. counts) }
end

--- Break a shell command into display lines at top-level operators (`&&`,
--- `||`, `|`, `;`) and at existing newlines, so a long chained command wraps
--- readably inside a ```bash fence. Quotes, backticks, `$()`/`${}` and heredocs
--- are copied verbatim (never split). Continuation lines are indented and lead
--- with the operator. Returns a list of single-line strings (no embedded
--- newlines), so callers can pass them straight to nvim_buf_set_lines.
function M.shell_lines(cmd, indent)
  cmd = (cmd or ""):gsub("^%s+", "")
  indent = indent or "    "
  local n = #cmd
  local lines = {}
  local cur = ""

  local function emit(s)
    s = s:gsub("%s+$", "")
    if s ~= "" then
      -- A quoted span may cross physical lines (e.g. a double-quoted
      -- `"$(cat <<'EOF' … EOF)"`); the quote handlers copy it verbatim, so
      -- split it here to guarantee every returned entry is a single line
      -- (nvim_buf_set_lines rejects strings containing '\n').
      for _, part in ipairs(vim.split(s, "\n", { plain = true })) do
        lines[#lines + 1] = part
      end
    end
  end

  -- Copy a heredoc body (already past the <<DELIM marker) verbatim, one line
  -- per entry, through its terminator line. Returns the index after the body.
  local function heredoc_body(j, delim)
    if cmd:sub(j, j) == "\n" then
      j = j + 1
    end
    while j <= n do
      local eol = cmd:find("\n", j, true)
      if not eol then
        lines[#lines + 1] = cmd:sub(j)
        return n + 1
      end
      local line = cmd:sub(j, eol - 1)
      lines[#lines + 1] = line
      j = eol + 1
      if line:gsub("^%s+", ""):gsub("%s+$", "") == delim then
        return j
      end
    end
    return j
  end

  local i = 1
  while i <= n do
    local ch = cmd:sub(i, i)
    local two = cmd:sub(i, i + 1)

    if ch == "\n" then
      emit(cur)
      cur = ""
      i = i + 1
    elseif two == "<<" then
      local j = i + 2
      if cmd:sub(j, j) == "-" then
        j = j + 1
      end
      local q = cmd:sub(j, j)
      if q == "'" or q == '"' then
        local close = cmd:find(q, j + 1, true)
        cur = cur .. cmd:sub(i, close or n)
        emit(cur)
        cur = ""
        i = heredoc_body((close or n) + 1, cmd:sub(j + 1, close and (close - 1) or n))
      elseif q:match("[%w_]") then
        local k = j
        while k <= n and cmd:sub(k, k):match("[%w_]") do
          k = k + 1
        end
        cur = cur .. cmd:sub(i, k - 1)
        emit(cur)
        cur = ""
        i = heredoc_body(k, cmd:sub(j, k - 1))
      else
        cur = cur .. two
        i = i + 2
      end
    elseif ch == "'" then
      local close = cmd:find("'", i + 1, true)
      cur = cur .. cmd:sub(i, close or n)
      i = (close or n) + 1
    elseif ch == '"' then
      local j = i + 1
      while j <= n do
        if cmd:sub(j, j) == "\\" then
          j = j + 2
        elseif cmd:sub(j, j) == '"' then
          break
        else
          j = j + 1
        end
      end
      cur = cur .. cmd:sub(i, math.min(j, n))
      i = math.min(j, n) + 1
    elseif ch == "`" then
      local close = cmd:find("`", i + 1, true)
      cur = cur .. cmd:sub(i, close or n)
      i = (close or n) + 1
    elseif two == "$(" then
      local j, depth = i + 2, 1
      while j <= n and depth > 0 do
        local c = cmd:sub(j, j)
        local tt = cmd:sub(j, j + 1)
        if c == "\\" then
          j = j + 2
        elseif tt == "$(" then
          depth = depth + 1
          j = j + 2
        elseif c == "(" then
          depth = depth + 1
          j = j + 1
        elseif c == ")" then
          depth = depth - 1
          j = j + 1
        else
          j = j + 1
        end
      end
      cur = cur .. cmd:sub(i, j - 1)
      i = j
    elseif two == "${" then
      local close = cmd:find("}", i + 2, true)
      cur = cur .. cmd:sub(i, close or n)
      i = (close or n) + 1
    elseif two == "&&" or two == "||" then
      emit(cur)
      cur = indent .. two .. " "
      i = i + 2
    elseif ch == "|" or ch == ";" then
      emit(cur)
      cur = indent .. ch .. " "
      i = i + 1
    else
      -- Collapse runs of unquoted spaces/tabs to a single space (shell word
      -- separators), which also drops the duplicate space right after a
      -- freshly-inserted operator separator.
      if (ch == " " or ch == "\t") and cur:match("[ \t]$") then
        -- skip
      else
        cur = cur .. ch
      end
      i = i + 1
    end
  end
  emit(cur)
  if #lines == 0 then
    lines[1] = ""
  end
  return lines
end

--- `<LeftMouse>` expr-map for read-only projection buffers: a click on a
--- closed fold opens it in place; a click on open content falls through to
--- Neovim's native click (cursor placement, drag-select). The open path uses
--- `:foldopen` (not `:normal`), which is allowed inside an expr map. Clicks in
--- a background split act there without stealing focus.
function M.mouse_fold()
  local pos = vim.fn.getmousepos()
  local win = pos.winid
  if win == 0 or not vim.api.nvim_win_is_valid(win) or pos.line <= 0 then
    return "<LeftMouse>"
  end
  local closed = vim.api.nvim_win_call(win, function()
    return vim.fn.foldclosed(pos.line)
  end)
  if closed == -1 then
    return "<LeftMouse>"
  end
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_cursor(win, { pos.line, 0 })
    vim.cmd(("%dfoldopen"):format(pos.line))
  end)
  return ""
end

return M
