-- Small cross-module helpers shared by the winbar and the send/backend
-- orchestration: the active provider/model combo for a buffer, and
-- human-readable token counts.

local M = {}

--- The combo yap will send with: per-buffer vars (set by :Yap),
--- falling back to the global config. Resolves `require("harness")` lazily
--- so this module can be loaded during the harness's own require cycle.
function M.current_combo(buf)
  local config = require("harness").config
  return vim.b[buf].yap_provider or config.provider, vim.b[buf].yap_model or config.model
end

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

return M
