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
-- by M.attach on managed session and scratch buffers.
local client_id = nil

-- Deduplicates the actionable missing-binary warning across sessions and
-- turns. Reset to false whenever the binary is found executable, so a later
-- disappearance (or a changed `bin` path) is reported again.
local missing_bin_warned = false

local function cfg()
  return require("harness").config
end

--- Whether the configured binary is executable right now. Re-checked on every
--- call, so a binary installed (or a PATH/config fix applied) later is picked
--- up without restarting Neovim. No warning here: setup()'s warm-up goes
--- through ensure() and must stay silent at startup.
function M.bin_available()
  local bin = cfg().bin
  if bin and bin ~= "" and vim.fn.executable(bin) == 1 then
    missing_bin_warned = false
    return true
  end
  return false
end

--- Surface one actionable warning when a managed session needs the binary and
--- it is missing (LSP attach or a turn). Deduplicated until the binary is
--- found again, so several sessions or turns do not each re-notify.
function M.warn_missing_bin()
  if M.bin_available() or missing_bin_warned then
    return
  end
  missing_bin_warned = true
  local bin = cfg().bin
  local label = (bin and bin ~= "") and ("'" .. bin .. "'") or "(empty bin)"
  vim.notify(
    "yap: binary "
      .. label
      .. " is not executable — install yap or set bin in setup() "
      .. "(LSP and turns stay off until it is available)",
    vim.log.levels.WARN
  )
end

--- Start the client once and return its id, or nil when the binary is
--- unavailable. The check is silent here (setup() warms the client up without
--- warning); callers that represent a managed session actually needing LSP
--- (M.attach) warn through M.warn_missing_bin.
function M.ensure()
  if client_id then
    local existing = vim.lsp.get_client_by_id(client_id)
    if existing and not existing:is_stopped() then
      return client_id
    end
  end
  if not M.bin_available() then
    return nil
  end
  local c = cfg()
  client_id = vim.lsp.start({
    name = "yap",
    cmd = { c.bin, "lsp" },
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
    M.warn_missing_bin()
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
    -- Notes are attached for @file completion, not transcript diagnostics.
    is_session = vim.b[buf].yap == true,
    is_scratch = vim.b[buf].yap_scratch_notes == true,
  })
end

-- The yap client, waited until the initialize handshake completes and it is
-- attached to buf, or nil when unavailable. The client starts eagerly at
-- setup(), so a session opened immediately afterwards can reach here before
-- initialize completes — and the didOpen for its buffer is only queued until
-- then. Wait for the handshake so the server answers about a document it
-- actually has, but bail out as soon as the client stops: when `bin` is not a
-- language server at all (test doubles, a build predating `yap lsp`) there is
-- nothing to wait for.
local function attached_client(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local id = client_id
  local client = id and vim.lsp.get_client_by_id(id) or nil
  if not client or client:is_stopped() or not vim.lsp.buf_is_attached(buf, id) then
    -- The client was never started, exited, or was stopped (a crash, :LspStop,
    -- a stray detach), or this buffer lost its attach when the client was
    -- restarted. M.attach is idempotent: it (re)starts the client, attaches
    -- this buffer and resends the editor context, so symbols, completion and
    -- the message preview keep working without re-adopting the session.
    M.attach(buf)
    id = client_id
    client = id and vim.lsp.get_client_by_id(id) or nil
  end
  if not client then
    return nil
  end
  if not (client.initialized and vim.lsp.buf_is_attached(buf, id)) then
    vim.wait(500, function()
      return client.initialized or client:is_stopped()
    end, 5)
    if not client.initialized or client:is_stopped() or not vim.lsp.buf_is_attached(buf, id) then
      return nil
    end
  end
  return client
end

--- Ask the backend for the document-symbol outline in server order (newest
--- message first, frontmatter block last). Returns a flat list of
--- { name = string, line = number } (line is 1-based) or nil when no client
--- is attached.
---@param buf integer
---@return {name:string, line:integer}[]|nil
function M.symbols(buf)
  local client = attached_client(buf)
  if not client then
    return nil
  end
  local res = client:request_sync("textDocument/documentSymbol", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
  }, 5000, buf)
  if type(res) ~= "table" or res.err or type(res.result) ~= "table" then
    return nil
  end
  local out = {}
  -- The frontmatter symbol carries each key as a child; flatten children so
  -- the picker lists the individual frontmatter items, not one bare block.
  local function add(sym)
    local start = sym.range and sym.range.start
    if start and type(start.line) == "number" then
      out[#out + 1] = { name = sym.name, line = start.line + 1 }
    end
    for _, child in ipairs(sym.children or {}) do
      add(child)
    end
  end
  for _, s in ipairs(res.result) do
    add(s)
  end
  return out
end

--- Ask the backend what this buffer would send. The transcript → request
--- conversion is Go-owned (R-single-reader), so the harness queries the
--- document server instead of re-deriving the flatten/merge/marker rules in
--- Lua. Returns nil when no client is attached, in which case the backend
--- validates the request itself on the next send.
---@param buf integer
---@return {role:string, content:string}[]|nil
function M.messages(buf)
  local client = attached_client(buf)
  if not client then
    return nil
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
