local M = {}
local max_bytes = 10 * 1024 * 1024

local paths = require("harness.path")

--- Append one `attachment` event to the session's audit log. Every attach
--- attempt is recorded: success carries the metadata (name, source, asset,
--- bytes, format); failure carries the error plus whatever was known. The
--- image bytes themselves are never logged.
local function record(buf, fields)
  fields.type = "attachment"
  fields.ts = os.date("%Y-%m-%dT%H:%M:%S")
  require("harness.agent.audit").append_event(buf, fields)
end

--- A filename safe to live in the session's assets folder: the basename kept
--- readable, stripping only the few characters that break paths or the
--- markdown reference.
local function safe_name(path)
  return vim.fs.basename(path):gsub("[%[%]\r\n]", "_")
end

--- The destination for `name` inside `dir`, deduped with a `-1`, `-2` … suffix
--- when a file of that name already exists (never overwrite an earlier import).
local function unique_dest(dir, name)
  local stem, ext = name:match("^(.-)(%.[^%.]+)$")
  if not stem then
    stem, ext = name, ""
  end
  local dest = dir .. "/" .. name
  local i = 1
  while vim.uv.fs_stat(dest) do
    dest = dir .. "/" .. stem .. "-" .. i .. ext
    i = i + 1
  end
  return dest
end

--- Turn a dropped, shell-escaped image path on the current user line into a
--- reference to a copy stored in the session's assets folder. Ghostty pastes
--- paths, not file contents.
function M.attach(buf, row)
  buf = buf or vim.api.nvim_get_current_buf()
  row = row or vim.api.nvim_win_get_cursor(0)[1]
  if not vim.b[buf].yap then
    return nil, "not a yap session"
  end
  local role
  for _, heading in ipairs(require("harness.model.structure").parse(buf).headings) do
    if heading.line > row then
      break
    end
    role = heading.role
  end
  if role ~= "user" then
    return nil, "drop a photo path on its own line in a user message"
  end
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  local path = line:match("^%s*(.-)%s*$"):gsub("\\(.)", "%1")
  if path:sub(1, 2) == "~/" then
    path = vim.env.HOME .. path:sub(2)
  end
  path = vim.fn.fnamemodify(path, ":p")
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size > max_bytes then
    local msg = "expected a local image file of at most 10 MiB: " .. path
    record(buf, { error = msg, source = path, bytes = stat and stat.size or nil })
    return nil, msg
  end
  local fd, err = vim.uv.fs_open(path, "r", 0)
  if not fd then
    record(buf, { error = err, source = path })
    return nil, err
  end
  local bytes, read_err = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if not bytes then
    record(buf, { error = read_err, source = path, bytes = stat.size })
    return nil, read_err
  end
  local ext
  if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then
    ext = ".png"
  elseif bytes:sub(1, 3) == "\255\216\255" then
    ext = ".jpg"
  else
    local msg = "only PNG and JPEG photos are supported"
    record(buf, { error = msg, source = path, bytes = #bytes })
    return nil, msg
  end
  local adir = paths.assets_dir(buf)
  paths.ensure_session_dir(adir)
  local dest = unique_dest(adir, safe_name(path))
  local out, open_err = vim.uv.fs_open(dest, "wx", 384) -- 0600; never overwrite an existing asset
  if not out then
    record(buf, { error = open_err, source = path, asset = dest, bytes = #bytes, format = ext:sub(2) })
    return nil, open_err
  end
  local written, write_err = vim.uv.fs_write(out, bytes, 0)
  vim.uv.fs_close(out)
  if written ~= #bytes then
    vim.uv.fs_unlink(dest)
    local msg = write_err or "incomplete image copy"
    record(buf, { error = msg, source = path, asset = dest, bytes = #bytes, format = ext:sub(2) })
    return nil, msg
  end
  local reference = "![FILE: " .. vim.fs.basename(dest) .. "](" .. vim.uri_from_fname(dest) .. ")"
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { reference })
  record(buf, {
    name = vim.fs.basename(dest),
    source = path,
    asset = dest,
    bytes = #bytes,
    format = ext:sub(2),
  })
  return reference
end

function M.import_paths(buf)
  local role
  local headings = require("harness.model.structure").parse(buf).headings
  local next_heading = 1
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if headings[next_heading] and headings[next_heading].line == row then
      role = headings[next_heading].role
      next_heading = next_heading + 1
    elseif role == "user" then
      local path = line:match("^%s*(/.-)%s*$")
      if path then
        local lower = path:lower()
        if lower:match("%.png$") or lower:match("%.jpe?g$") then
          local ref, err = M.attach(buf, row)
          if not ref then
            return nil, err
          end
        end
      end
    end
  end
  return true
end

return M
