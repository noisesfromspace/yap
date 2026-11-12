-- Request-only "hidden" context: transient, environment-dependent state
-- appended to the trailing user message on every send.
--
-- It is never stored in the session buffer. Changing a provider's output can
-- invalidate cross-turn prompt cache reuse because previous tails are absent
-- from the stored history. Yap ships no built-in providers.
--
-- Providers are functions returning a string (or nil/"" to contribute
-- nothing). Plugins may add providers with
-- `require("harness.model.context").register(fn[, order])`.

local M = {}

local providers = {}

--- Register a context provider. `fn()` runs on every send with no arguments
--- and returns a string to append, or nil/"" to skip. Lower `order` runs
--- first.
function M.register(fn, order)
  vim.validate({ fn = { fn, "function" }, order = { order, "number", true } })
  providers[#providers + 1] = { fn = fn, order = order or 100 }
  table.sort(providers, function(a, b)
    return a.order < b.order
  end)
end

--- Remove every provider (re-setup and tests only).
function M.reset()
  providers = {}
end

--- Run every provider and return the joined section, or nil when nothing
--- contributed. A throwing provider is skipped with a warning so one broken
--- plugin cannot break every send.
function M.snapshot()
  local parts = {}
  for _, p in ipairs(providers) do
    local ok, text = pcall(p.fn)
    if not ok then
      vim.notify("yap: context provider failed: " .. tostring(text), vim.log.levels.WARN)
    elseif type(text) == "string" and text ~= "" then
      parts[#parts + 1] = text
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "\n\n")
end

return M
