-- pitel session persistence & picker.
--
-- A pitel session is just the buffer's markdown written to a file — the
-- buffer IS the conversation, so the file is a lossless serialization.
-- Sessions live under ~/.pitel/sessions/<cwd-slug>/ and are
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
---
--- The write goes through `:write!` (not writefile()): the buffer then
--- OWNS the file in Neovim's eyes — mtime bookkeeping is set, so `:w`
--- keeps working and you never get E13 "file exists". `:write!` also
--- clears 'modified', so a clean buffer prompts nothing on exit; the
--- `[+]` flag is the real signal for "typed but not yet saved".
--- Writing without 'modified' is harmless.
function M.save(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local path = vim.b[buf].pitel_path
  local bufname = vim.api.nvim_buf_get_name(buf)
  -- Follow buffer renames (:file, :saveas): renaming the file IS session
  -- naming, and :saveas to a new file IS forking.
  if path and bufname ~= "" and bufname ~= path and not bufname:match("^%a+://") then
    path = bufname
    vim.b[buf].pitel_path = path
  end
  if not path then
    local dir = session_dir(vim.fn.getcwd())
    vim.fn.mkdir(dir, "p")
    path = string.format("%s/%s-%04x.md", dir, os.date("%Y%m%d-%H%M%S"), math.random(0, 0xffff))
    vim.b[buf].pitel_path = path
    pcall(vim.api.nvim_buf_set_name, buf, path)
  end
  local view = vim.api.nvim_get_current_buf() == buf and vim.fn.winsaveview() or nil
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent noautocmd keepjumps write!")
  end)
  if view then
    vim.fn.winrestview(view)
  end
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
      local stem = vim.fn.fnamemodify(path, ":t:r")
      -- Auto-generated names start with the timestamp; anything else is a
      -- user-chosen session name, shown as-is.
      local ts = stem:match("^(%d+%-%d+)")
      local snippet = first_user_snippet(lines)
      local label = (ts or stem) .. "  " .. (snippet ~= "" and snippet or "(no user message)")
      if scope == "all" then
        label = label .. "  —  " .. vim.fn.fnamemodify(dir, ":t")
      end
      table.insert(items, { path = path, mtime = vim.fn.getftime(path), text = label })
    end
  end

  table.sort(items, function(a, b)
    return a.mtime > b.mtime
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
