-- Small cross-module helpers shared by the winbar and the send/backend
-- orchestration: human-readable token counts and buffer lookup.

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

--- Find a buffer by name, or create one (unlisted) with that name.
--- Reuse comes first: naming a fresh buffer identically to a leftover
--- would E95 (the chat buffer may have been wiped and reopened). Returns
--- the buffer and whether it was freshly created.
function M.find_or_create_buffer(name, listed, scratch)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return b, false
    end
  end
  local b = vim.api.nvim_create_buf(listed, scratch)
  vim.api.nvim_buf_set_name(b, name)
  return b, true
end

return M
