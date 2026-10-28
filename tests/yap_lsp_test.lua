-- yap session buffers carry exactly one language server: the `yap lsp`
-- client (symbols, completion, diagnostics). Any other client that attaches
-- is detached buffer-locally (not stopped, so a shared server keeps serving
-- ordinary files). This covers both directions: a markdown client that
-- attached during :edit before the buffer was marked, and one that attaches
-- later via LspAttach.

local real = {
  start = vim.lsp.start,
  get_clients = vim.lsp.get_clients,
  get_client_by_id = vim.lsp.get_client_by_id,
  buf_detach_client = vim.lsp.buf_detach_client,
  buf_attach_client = vim.lsp.buf_attach_client,
  buf_is_attached = vim.lsp.buf_is_attached,
  executable = vim.fn.executable,
}

local detached = {}
local attached = {}
local notified = {}
local yap_client_id = 42

local function fake_client(id)
  return {
    id = id,
    exit_timeout = 0,
    rpc = { is_closing = function() return true end },
    stop = function()
      detached.stop = (detached.stop or 0) + 1
    end,
    notify = function(self, method, params)
      notified[id] = params
    end,
  }
end

vim.fn.executable = function()
  return 1
end
vim.lsp.start = function()
  return yap_client_id
end
vim.lsp.get_client_by_id = function(id)
  if id == yap_client_id then
    return fake_client(id)
  end
end
vim.lsp.get_clients = function()
  return { fake_client(7) }
end
vim.lsp.buf_detach_client = function(_, id)
  detached[id] = (detached[id] or 0) + 1
end
vim.lsp.buf_attach_client = function(buf, id)
  attached[id] = buf
  return true
end
vim.lsp.buf_is_attached = function()
  return false
end

local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })

-- 1. a new yap buffer is marked; a pre-attached markdown client is detached
--    (not stopped), and the yap client is attached.
local buf = yap.new({ provider = "mock", model = "m1" })
assert(vim.b[buf].yap == true, "yap buffer was not marked")
assert(detached[7] == 1, "pre-attached markdown client was not detached")
assert(detached.stop == nil, "markdown client was stopped instead of detached")
assert(attached[yap_client_id] == buf, "yap client was not attached")

-- 2. the LspAttach guard detaches a late non-yap client but lets the yap
--    client through.
vim.api.nvim_exec_autocmds("LspAttach", {
  buffer = buf,
  data = { client_id = 99 },
})
assert(detached[99] == 1, "LspAttach guard did not detach a late client")
vim.api.nvim_exec_autocmds("LspAttach", {
  buffer = buf,
  data = { client_id = yap_client_id },
})
assert(detached[yap_client_id] == nil, "LspAttach guard detached the yap client")

-- 3. a non-yap buffer is left alone by the guard.
local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_exec_autocmds("LspAttach", {
  buffer = other,
  data = { client_id = 100 },
})
assert(detached[100] == nil, "LspAttach guard detached a client on a non-yap buffer")

-- Restore the real functions before exit (see the comment at the top of the
-- original test: core vim.lsp's VimLeavePre iterates get_clients()).
vim.lsp.start = real.start
vim.lsp.get_clients = real.get_clients
vim.lsp.get_client_by_id = real.get_client_by_id
vim.lsp.buf_detach_client = real.buf_detach_client
vim.lsp.buf_attach_client = real.buf_attach_client
vim.lsp.buf_is_attached = real.buf_is_attached
vim.fn.executable = real.executable

print("yap LSP guard: detaches other clients, attaches the yap client, leaves others alone")
