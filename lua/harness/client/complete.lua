-- A completion source for nvim-cmp and blink.cmp that routes session
-- completion through the `yap lsp` client. The harness enables Neovim's
-- builtin vim.lsp.completion by default (harness/init.lua); users on their own
-- completion engine add this source instead:
--
--   -- nvim-cmp
--   require("cmp").register_source("yap", require("harness.client.complete").cmp())
--
--   -- blink.cmp (blink calls require(module).new())
--   require("blink.cmp").setup({
--     sources = { providers = { yap = { module = "harness.client.complete" } } },
--   })
--
-- It is a thin adapter: it only decides WHEN to ask (the trigger gate below)
-- and forwards the request to the server, which computes every item.
-- No completion items or frontmatter fields live here (R-language-intelligence).

local M = {}

-- The server's advertised trigger characters (@file, # @role, `: value`,
-- `- list item`). Frontmatter keys have no trigger character, so they arrive
-- through the keyword pattern below.
local TRIGGERS = { "@", "#", ":", "-" }
-- nvim-cmp expects a Vim regex (not a Lua pattern). Blink uses its own
-- keyword detection; trigger characters handle @path and frontmatter values.
local KEYWORD = [[\k\+]]

local function yap_client(buf)
  return vim.lsp.get_clients({ bufnr = buf, name = "yap" })[1]
end

-- Byte offset -> UTF-16 code units, matching the position encoding the server
-- negotiates (positionEncoding: utf-16).
local function utf16_col(line, byte_col)
  local _, col = vim.str_utfindex(line, byte_col)
  return col
end

--- Whether completion can produce anything at the cursor. This mirrors the
--- server's dispatch (frontmatter / `# @role` / `@file`) only to suppress the
--- popup in message prose, where the server answers with nothing; the items
--- themselves are computed in Go.
local function wants(buf)
  if not (vim.api.nvim_buf_is_valid(buf) and (vim.b[buf].yap or vim.b[buf].yap_scratch_notes)) then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  local cur = vim.api.nvim_get_current_line()
  -- Frontmatter: cursor strictly between the opening and closing `---`. Read
  -- only the first 200 lines — the server caps its frontmatter scan the same
  -- way, and the gate must not read a whole long session per keystroke.
  local count = vim.api.nvim_buf_line_count(buf)
  local top = vim.api.nvim_buf_get_lines(buf, 0, math.min(count, 200), false)
  if top[1] == "---" then
    for i = 2, #top do
      if top[i] == "---" then
        if row >= 2 and row < i then
          return true
        end
        break
      end
    end
  end
  if vim.startswith(cur, "# @") then
    return true
  end
  -- @file reference: a `@` at a word boundary, followed by path characters up
  -- to the cursor.
  local before = cur:sub(1, col)
  local start = before:match("()@[%w_./~-]*$")
  return start ~= nil and (start == 1 or before:sub(start - 1, start - 1):match("^[ \t]$") ~= nil)
end

--- Forward a textDocument/completion request to the yap client and hand the
--- server's items back. `callback` receives the raw CompletionItem[] (both
--- engines accept LSP-shaped items unchanged), or {} when no client answers.
function M.items(buf, callback)
  local client = yap_client(buf)
  if not client then
    callback({})
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  local cur = vim.api.nvim_get_current_line()
  client:request("textDocument/completion", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = row - 1, character = utf16_col(cur, col) },
  }, function(err, result)
    if err or type(result) ~= "table" then
      callback({})
      return
    end
    local items = result.items or result
    callback(type(items) == "table" and items or {})
  end, buf)
end

--- The nvim-cmp source. Register with cmp.register_source and list it as a
--- `{ name = "yap" }` source.
function M.cmp()
  return {
    name = "yap",
    get_trigger_characters = function()
      return TRIGGERS
    end,
    get_keyword_pattern = function()
      return KEYWORD
    end,
    is_available = function()
      return wants(vim.api.nvim_get_current_buf())
    end,
    complete = function(_, params, callback)
      local buf = params.context.bufnr
      M.items(buf, function(items)
        callback({ items = items, isIncomplete = false })
      end)
    end,
  }
end

--- The blink.cmp provider. Point blink's `module` option at this module
--- (blink calls require(module).new()).
function M.new()
  return {
    name = "yap",
    enabled = function()
      return wants(vim.api.nvim_get_current_buf())
    end,
    get_trigger_characters = function()
      return TRIGGERS
    end,
    get_completions = function(ctx, callback)
      local buf = ctx.bufnr
      M.items(buf, function(items)
        callback({ items = items, is_incomplete = false })
      end)
    end,
  }
end

return M
