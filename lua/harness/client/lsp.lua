-- yap LSP integration: start the `yap lsp` language server and attach it to
-- managed session buffers only. The server (agent/lsp) provides document
-- symbols, completion and diagnostics; this module owns only the plumbing —
-- client lifecycle, attachment scope and editor context — none of the parsing
-- or feature logic. Folding, text objects and navigation stay local and
-- synchronous (see CONTRIBUTING.md R-single-reader / R-language-intelligence).

local M = {}

local state = require("harness.state")

-- The running client id, or nil. One client serves every session buffer in
-- this Neovim instance; it is never auto-attached by root_dir/filetype, only
-- by M.attach on buffers that carry b:yap.
local client_id = nil

local function cfg()
  return require("harness").config
end

--- Start the client once and return its id, or nil when the binary is
--- unavailable (a missing binary is not an error: the features simply stay off).
function M.ensure()
  if client_id and vim.lsp.get_client_by_id(client_id) then
    return client_id
  end
  local c = cfg()
  local bin = c.bin
  if not bin or bin == "" or vim.fn.executable(bin) ~= 1 then
    return nil
  end
  client_id = vim.lsp.start({
    name = "yap",
    cmd = { bin, "lsp" },
    root_dir = c.sessions_dir or vim.fn.getcwd(),
    capabilities = vim.lsp.protocol.make_client_capabilities(),
    init_options = {
      sessions_dir = c.sessions_dir,
      agents_dir = c.agents_dir,
      models_cache = require("harness.config").models_cache_path(),
    },
    on_exit = function()
      client_id = nil
    end,
  }, { attach = false, silent = true })
  return client_id
end

--- Whether id is the yap client. The LspAttach guard in setup() lets this one
--- client through while detaching ordinary language servers from session
--- buffers.
function M.is_yap_client(id)
  return id ~= nil and id == client_id
end

--- Attach the yap client to a managed session buffer and (re)send its editor
--- context. Idempotent.
function M.attach(buf)
  local id = M.ensure()
  if not id then
    return
  end
  if not vim.lsp.buf_is_attached(buf, id) then
    vim.lsp.buf_attach_client(buf, id)
  end
  M.notify_context(buf)
end

--- Send the current editor context (cwd + streaming state) to the server.
function M.notify_context(buf)
  M.notify(buf, vim.fn.getcwd(), state.running[buf] ~= nil)
end

--- Send an explicit streaming state (the caller already knows it).
function M.notify_streaming(buf, streaming)
  M.notify(buf, vim.fn.getcwd(), streaming)
end

function M.notify(buf, cwd, streaming)
  local id = client_id
  if not id then
    return
  end
  local client = vim.lsp.get_client_by_id(id)
  if not client or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  client:notify("yap/context", {
    uri = vim.uri_from_bufnr(buf),
    cwd = cwd or "",
    streaming = streaming == true,
  })
end

--- Ask the backend what this buffer would send. The transcript → request
--- conversion is Go-owned (R-single-reader), so the harness queries the
--- document server instead of re-deriving the flatten/merge/marker rules in
--- Lua. Returns nil when no client is attached, in which case the backend
--- validates the request itself on the next send.
---@param buf integer
---@return {role:string, content:string}[]|nil
function M.messages(buf)
  local id = client_id
  if not id or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local client = vim.lsp.get_client_by_id(id)
  if not client then
    return nil
  end
  -- The client starts eagerly at setup(), so a session opened immediately
  -- afterwards can reach here before initialize completes — and the didOpen
  -- for its buffer is only queued until then. Wait for the handshake so the
  -- server answers about a document it actually has, but bail out as soon as
  -- the client stops: when `bin` is not a language server at all (test
  -- doubles, a build predating `yap lsp`) there is nothing to wait for.
  if not (client.initialized and vim.lsp.buf_is_attached(buf, id)) then
    vim.wait(500, function()
      return client.initialized or client:is_stopped()
    end, 5)
    if not client.initialized or client:is_stopped() or not vim.lsp.buf_is_attached(buf, id) then
      return nil
    end
  end
  -- Include the current snapshot: buffer adoption/rename can race core's
  -- didOpen/didChange tracking, but send conversion must always see the text
  -- that is actually in this buffer. Go still owns all parsing.
  local res = client:request_sync("yap/messages", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
  }, 5000, buf)
  if type(res) ~= "table" or res.err or type(res.result) ~= "table" then
    return nil
  end
  return res.result
end

return M
