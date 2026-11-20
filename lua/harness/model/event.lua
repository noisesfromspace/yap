-- Display-only events persisted in the Markdown transcript.
local M = {}

function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function M.line(kind, text, fields)
  local event = vim.tbl_extend("keep", fields or {}, { type = kind, text = text, ts = M.now() })
  -- A path or other string may contain an HTML comment terminator.
  local json = vim.json.encode(event):gsub(">", "\\u003e"):gsub("<", "\\u003c")
  return "<!-- yap:event " .. json .. " -->"
end

return M
