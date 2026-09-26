-- pitel session persistence & picker.
--
-- A pitel session is just the buffer's markdown written to a file — the
-- buffer IS the conversation, so the file is a lossless serialization.
-- Sessions live under stdpath("data")/pitel/sessions/<cwd-slug>/ and are
-- autosaved after every completed reply. The picker lists them with the
-- first user message as a snippet, fruit.nvim-style.

local M = {}

local function sessions_root()
  return vim.fn.expand("~/.pitel/sessions")
end

local function cwd_slug(cwd)
  return (cwd:gsub("[^%w%._-]", "-"))
end

local function session_dir(cwd)
  return sessions_root() .. "/" .. cwd_slug(vim.fs.normalize(cwd))
end

--- Write the buffer to its session file, creating one (named after the
--- current time) on first save. Renames the buffer to the file so `:w`
--- works as expected.
function M.save(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local path = vim.b[buf].pitel_path
  if not path then
    local dir = session_dir(vim.fn.getcwd())
    vim.fn.mkdir(dir, "p")
    path = string.format("%s/%s-%04x.md", dir, os.date("%Y%m%d-%H%M%S"), math.random(0, 0xffff))
    vim.b[buf].pitel_path = path
    pcall(vim.api.nvim_buf_set_name, buf, path)
  end
  vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), path)
  vim.bo[buf].modified = false
end

-- First non-empty line of the first `# @user` block, compacted.
local function first_user_snippet(lines)
  local in_user = false
  for _, line in ipairs(lines) do
    if line:match("^# @%a+%s*$") then
      in_user = line:match("^# @user%s*$") ~= nil
    elseif in_user then
      local text = line:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      if text ~= "" then
        if #text > 60 then
          return text:sub(1, 60) .. "…"
        end
        return text
      end
    end
  end
  return ""
end

--- List saved sessions. scope = "cwd" (default) or "all".
--- Items: { path, created, text } sorted newest first.
function M.list(scope)
  local dirs
  if scope == "all" then
    dirs = vim.fn.glob(sessions_root() .. "/*", false, true)
  else
    dirs = { session_dir(vim.fn.getcwd()) }
  end

  local items = {}
  for _, dir in ipairs(dirs) do
    for _, path in ipairs(vim.fn.glob(dir .. "/*.md", false, true)) do
      local lines = vim.fn.readfile(path, "", 200)
      local ts = vim.fn.fnamemodify(path, ":t"):match("^(%d+%-%d+)") or ""
      local snippet = first_user_snippet(lines)
      local label = ts .. "  " .. (snippet ~= "" and snippet or "(no user message)")
      if scope == "all" then
        label = label .. "  —  " .. vim.fn.fnamemodify(dir, ":t")
      end
      table.insert(items, { path = path, created = ts, text = label })
    end
  end

  table.sort(items, function(a, b)
    return a.created > b.created
  end)
  return items
end

local function preview_item(item)
  local lines = vim.fn.readfile(item.path)
  local n = math.min(80, #lines)
  local preview = { "# pitel session", "", item.path, "", "showing last " .. n .. "/" .. #lines .. " lines", "" }
  for i = #lines - n + 1, #lines do
    table.insert(preview, lines[i])
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, preview)
  vim.bo[buf].bufhidden = "wipe"
  return { buf = buf, pos = { 1, 0 } }
end

--- Pick a session; on_choice(path) is called with the selected file.
function M.pick(opts, on_choice)
  opts = opts or {}
  local items = M.list(opts.scope == "all" and "all" or "cwd")
  if #items == 0 then
    vim.notify("pitel: no saved sessions", vim.log.levels.INFO)
    return
  end
  vim.ui.select(items, {
    prompt = "Pick pitel session (" .. (opts.scope == "all" and "all projects" or "cwd project") .. ")",
    kind = "pitel_session",
    format_item = function(item)
      return item.text
    end,
    preview_item = preview_item,
  }, function(choice)
    if choice then
      on_choice(choice.path)
    end
  end)
end

return M
