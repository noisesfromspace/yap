-- :YapAudit — a split-panel browser for the session's raw JSONL audit
-- log. The left pane is the raw file (one event per line, colored by
-- type, so :YapClear's path:line references stay exact); the right pane
-- is a readable rendering of the event under the cursor. The raw file is
-- never rewritten.

local M = {}

local paths = require("harness.path")

local ns = vim.api.nvim_create_namespace("yap.audit")

-- Event type -> highlight group for the left list.
local TYPE_HL = {
  tool_call = "YapAuditTool",
  tool_result = "YapAuditResult",
  tool_start = "YapAuditTool",
  output = "YapAuditOutput",
  turn_end = "YapAuditTurn",
  retry = "YapAuditWarn",
  tool_text_warning = "YapAuditWarn",
  steer = "YapAuditWarn",
  approval_request = "YapAuditWarn",
  approval_result = "YapAuditWarn",
  approval_timeout = "YapAuditWarn",
}

local function link(name, to)
  vim.api.nvim_set_hl(0, name, { link = to, default = true })
end
link("YapAuditTool", "Function")
link("YapAuditResult", "String")
link("YapAuditOutput", "Comment")
link("YapAuditTurn", "Title")
link("YapAuditWarn", "WarningMsg")

local state = {}

--- Render one decoded event as readable lines: fields sorted, and multiline
--- string fields (results, output chunks) emitted as raw text so they read
--- as prose instead of escaped JSON.
local function render_record(ev)
  if type(ev) ~= "table" or next(ev) == nil then
    return { vim.json.encode(ev) }
  end
  local keys = vim.tbl_keys(ev)
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    local v = ev[k]
    if type(v) == "string" and v:find("\n", 1, true) then
      out[#out + 1] = vim.json.encode(k) .. ":"
      for _, l in ipairs(vim.split(v, "\n", { plain = true })) do
        out[#out + 1] = "  " .. l
      end
    else
      out[#out + 1] = string.format("%s: %s", vim.json.encode(k), vim.json.encode(v))
    end
  end
  return out
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function highlight_source(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    if line ~= "" then
      local ok, ev = pcall(vim.json.decode, line)
      if ok and type(ev) == "table" then
        local hl = TYPE_HL[ev.type]
        if hl then
          vim.api.nvim_buf_add_highlight(buf, ns, hl, i - 1, 0, -1)
        end
      end
    end
  end
end

local function update_preview()
  local source, preview = state.source_buf, state.preview_buf
  if not (source and preview and vim.api.nvim_buf_is_valid(source) and vim.api.nvim_buf_is_valid(preview)) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(state.source_win)[1]
  local line = vim.api.nvim_buf_get_lines(source, cursor - 1, cursor, false)[1]
  local out
  if not line or line == "" then
    out = { "" }
  else
    local ok, ev = pcall(vim.json.decode, line)
    if ok and type(ev) == "table" then
      out = render_record(ev)
    else
      out = { "(invalid JSON) " .. tostring(ev) }
    end
  end
  set_lines(preview, out)
end

local function close()
  for _, win in ipairs({ state.preview_win, state.source_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  state.source_buf, state.preview_buf = nil, nil
  state.source_win, state.preview_win = nil, nil
end

--- Open the split-panel viewer for a JSONL path.
function M.open(path)
  close() -- one viewer at a time

  local lines = vim.fn.readfile(path)

  local source = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(source, "yap://audit:" .. path)
  vim.bo[source].buftype = "nofile"
  vim.bo[source].bufhidden = "wipe"
  vim.bo[source].swapfile = false
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  vim.bo[source].modifiable = false
  highlight_source(source, lines)

  local preview = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(preview, "yap://audit-preview")
  vim.bo[preview].buftype = "nofile"
  vim.bo[preview].bufhidden = "wipe"
  vim.bo[preview].swapfile = false
  vim.bo[preview].modifiable = false

  -- Source to the right of the current window, preview to the right of it,
  -- so the chat (or whatever buffer) is left untouched.
  vim.cmd("rightbelow vsplit")
  local source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(source_win, source)
  vim.wo[source_win].wrap = false
  vim.wo[source_win].cursorline = true

  vim.cmd("rightbelow vsplit")
  local preview_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(preview_win, preview)
  vim.wo[preview_win].foldmethod = "indent"
  vim.wo[preview_win].foldlevel = 99

  state.source_buf = source
  state.preview_buf = preview
  state.source_win = source_win
  state.preview_win = preview_win

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = source,
    callback = update_preview,
  })

  for _, b in ipairs({ source, preview }) do
    vim.keymap.set("n", "q", close, { buffer = b, silent = true, desc = "Close audit viewer" })
  end

  vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
  update_preview()
end

--- :YapAudit — open the current session's audit log. Works only in a yap
--- buffer (the audit log is keyed off the session's basename and cwd).
function M.view()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.b[buf].yap then
    vim.notify("yap: :YapAudit only works in a yap session", vim.log.levels.WARN)
    return
  end
  local path = paths.audit_path(buf)
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("yap: no audit log yet for this session", vim.log.levels.WARN)
    return
  end
  M.open(path)
end

return M
