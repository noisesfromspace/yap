local M = {}
local max_bytes = 10 * 1024 * 1024

--- Turn a dropped, shell-escaped image path on the current user line into a
--- durable local reference. Ghostty pastes paths, not file contents.
function M.attach(buf, row)
  buf = buf or vim.api.nvim_get_current_buf()
  row = row or vim.api.nvim_win_get_cursor(0)[1]
  if not vim.b[buf].yap then
    return nil, "not a yap session"
  end
  local role
  for _, heading in ipairs(require("harness.structure").parse(buf).headings) do
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
    return nil, "expected a local image file of at most 10 MiB: " .. path
  end
  local fd, err = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return nil, err
  end
  local bytes, read_err = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if not bytes then
    return nil, read_err
  end
  local ext
  if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then
    ext = ".png"
  elseif bytes:sub(1, 3) == "\255\216\255" then
    ext = ".jpg"
  else
    return nil, "only PNG and JPEG photos are supported"
  end
  local dir = vim.fn.stdpath("data") .. "/yap/assets"
  vim.fn.mkdir(dir, "p", 448) -- 0700
  local dest = dir .. "/" .. vim.fn.sha256(vim.base64.encode(bytes)) .. ext
  if not vim.uv.fs_stat(dest) then
    local out, open_err = vim.uv.fs_open(dest, "wx", 384) -- 0600; never overwrite an existing asset
    if not out then
      return nil, open_err
    end
    local written, write_err = vim.uv.fs_write(out, bytes, 0)
    vim.uv.fs_close(out)
    if written ~= #bytes then
      vim.uv.fs_unlink(dest)
      return nil, write_err or "incomplete image copy"
    end
  end
  local name = vim.fs.basename(path):gsub("[%[%]\r\n]", "_")
  local reference = "![FILE: " .. name .. "](" .. vim.uri_from_fname(dest) .. ")"
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { reference })
  return reference
end

function M.import_paths(buf)
  local role
  local headings = require("harness.structure").parse(buf).headings
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
