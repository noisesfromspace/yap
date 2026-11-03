-- Small cross-module helpers shared by the winbar and the send/backend
-- orchestration: human-readable token counts, buffer lookup, and the
-- statusline redraw every animation/stream path needs.

local M = {}

--- 1234 -> "1.2k", 1234567 -> "1.2m"; exact integers drop the decimal.
function M.fmt_tokens(n)
  local value, suffix
  if n >= 1000000 then
    value, suffix = n / 1000000, "m"
  elseif n >= 1000 then
    value, suffix = n / 1000, "k"
  else
    return tostring(n)
  end
  if value == math.floor(value) then
    return string.format("%d%s", value, suffix)
  end
  return string.format("%.1f%s", value, suffix)
end

--- Redraw the statusline/winbar, ignoring a CTRL-C that lands mid-command.
--- Nvim turns an interrupt that arrives while a command runs into an error
--- ("Keyboard interrupt") and clears got_int, so a cosmetic redraw fired from
--- a timer or a scheduled callback would otherwise throw out of the event
--- loop whenever the key arrives at the wrong microsecond. Anything else is a
--- real error and still propagates.
function M.redraw_status()
  local ok, err = pcall(vim.cmd.redrawstatus)
  if not ok and not tostring(err):find("Keyboard interrupt", 1, true) then
    error(err)
  end
end

--- Find a buffer by name, or create one (unlisted) with that name.
--- Reuse comes first: naming a fresh buffer identically to a leftover
--- would E95 (the session buffer may have been wiped and reopened). Returns
--- the buffer and whether it was freshly created. bufname() preserves the
--- display name; nvim_buf_get_name() would expand plain labels to cwd paths.
function M.find_or_create_buffer(name, listed, scratch)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.bufname(b) == name then
      return b, false
    end
  end
  local b = vim.api.nvim_create_buf(listed, scratch)
  vim.api.nvim_buf_set_name(b, name)
  return b, true
end

return M
