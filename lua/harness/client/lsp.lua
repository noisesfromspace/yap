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

return M
