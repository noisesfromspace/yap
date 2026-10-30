-- The cmp/blink completion source: a thin adapter over the yap lsp client.
-- It gates WHEN to ask (frontmatter / # @role / @file, never prose) and
-- forwards textDocument/completion; every item comes from the server.

local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local source = require("harness.client.complete")

-- Fake yap client: record the request, answer with one fixed item.
local requests = {}
local item = {
  label = "model",
  kind = 5,
  detail = "model id",
  textEdit = {
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } },
    newText = "model",
  },
}
local real_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function()
  return {
    {
      id = 42,
      request = function(_, method, params, cb)
        requests[#requests + 1] = { method = method, params = params }
        cb(nil, { isIncomplete = false, items = { item } })
      end,
    },
  }
end

local buf = vim.api.nvim_create_buf(false, false)
vim.b[buf].yap = true
vim.api.nvim_set_current_buf(buf)

local function at(row, col, lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { row, col })
end

local cmp_source = source.cmp()
local blink_source = source.new()

-- 1. The availability gate mirrors the server's dispatch: never prose, never
-- a non-yap buffer; yes in frontmatter, on a # @role line, and after an
-- @file word.
at(2, 0, { "# @user", "", "hello world" })
assert(cmp_source.is_available() == false, "prose should not offer completion")
at(2, 3, { "---", "prov", "model: foo", "---", "# @user", "hi" })
assert(cmp_source.is_available() == true, "frontmatter key should offer completion")
at(4, 0, { "---", "prov", "model: foo", "---", "# @user", "hi" })
assert(cmp_source.is_available() == false, "past the closing --- is not frontmatter")
at(1, 3, { "# @us" })
assert(cmp_source.is_available() == true, "# @role should offer completion")
at(1, 3, { "@fla" })
assert(cmp_source.is_available() == true, "@file should offer completion")
at(1, 6, { "see @flake.lock" })
assert(cmp_source.is_available() == true, "mid-line @file should offer completion")

local other = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(other)
assert(cmp_source.is_available() == false, "non-yap buffer should not offer completion")
assert(blink_source.enabled() == false, "blink source enabled on a non-yap buffer")
vim.api.nvim_set_current_buf(buf)

-- 2. cmp complete() forwards the request with the cursor as an LSP position
-- (0-based line, UTF-16 character) and passes the server's items through.
at(2, 3, { "---", "prov", "model: foo", "---", "# @user", "hi" })
local got
cmp_source.complete(nil, { context = { bufnr = buf } }, function(res)
  got = res
end)
assert(#requests == 1, "expected one completion request, got " .. #requests)
assert(requests[1].method == "textDocument/completion", "wrong method: " .. tostring(requests[1].method))
assert(requests[1].params.position.line == 1, "wrong line: " .. vim.inspect(requests[1].params.position))
assert(requests[1].params.position.character == 3, "wrong character: " .. vim.inspect(requests[1].params.position))
assert(requests[1].params.textDocument.uri == vim.uri_from_bufnr(buf), "wrong uri")
assert(got ~= nil and got.items[1] == item and got.isIncomplete == false, "items not passed through")

-- An astral character before the cursor counts as two UTF-16 units, not
-- four UTF-8 bytes or one Unicode code point.
at(2, 8, { "---", "prov😀x", "---" })
cmp_source.complete(nil, { context = { bufnr = buf } }, function() end)
assert(requests[2].params.position.character == 6, "wrong UTF-16 offset")

-- 3. blink get_completions() forwards the same way.
requests = {}
local bgot
blink_source.get_completions({ bufnr = buf }, function(res)
  bgot = res
end)
assert(bgot ~= nil and bgot.items[1] == item and bgot.is_incomplete == false, "blink items not passed through")
assert(#requests == 1, "blink did not forward one request")
vim.lsp.get_clients = real_get_clients

print("yap completion source: gated cmp/blink adapter over the yap lsp client")
