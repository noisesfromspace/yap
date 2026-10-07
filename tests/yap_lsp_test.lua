-- yap buffers must not carry a language server: the buffer is the
-- conversation (R-buffer-only-state), and a markdown LSP's semantic-token/inlay-hint stream is
-- pure per-redraw cost on a large session. The guard marks buffers in
-- setup_buffer and stops clients in both directions: already-attached clients
-- (a session opened with :edit) and clients that attach later (LspAttach).

-- Stub vim.lsp so the stop path is testable without a real server. Save the
-- originals and restore them before the process exits: core vim.lsp's
-- VimLeavePre handler iterates get_clients() and expects real client objects,
-- so the fake must not outlive the test.
local real_get_clients = vim.lsp.get_clients
local real_get_client_by_id = vim.lsp.get_client_by_id

local stopped = {}

local function fake_client(id)
  return {
    id = id,
    stop = function(self)
      stopped[self.id] = (stopped[self.id] or 0) + 1
    end,
  }
end

vim.lsp.get_clients = function()
  return { fake_client(7) }
end
vim.lsp.get_client_by_id = function(id)
  if id == 99 then
    return fake_client(id)
  end
end

local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })

-- 1. a new yap buffer is marked, and a pre-attached markdown client is stopped
local buf = yap.new({ provider = "mock", model = "m1" })
assert(vim.b[buf].yap == true, "yap buffer was not marked")
assert(stopped[7] == 1, "pre-attached LSP client was not stopped")

-- 2. the LspAttach guard stops a client that attaches after setup
vim.api.nvim_exec_autocmds("LspAttach", {
  buffer = buf,
  data = { client_id = 99 },
})
assert(stopped[99] == 1, "LspAttach guard did not stop a client on a yap buffer")

-- 3. a non-yap buffer is left alone by the guard
local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_exec_autocmds("LspAttach", {
  buffer = other,
  data = { client_id = 100 },
})
assert(stopped[100] == nil, "LspAttach guard stopped a client on a non-yap buffer")

-- Restore the real LSP functions before exit (see the comment at the top).
vim.lsp.get_clients = real_get_clients
vim.lsp.get_client_by_id = real_get_client_by_id

print("yap LSP guard: marked, stopped pre-attached and late clients, left others alone")
