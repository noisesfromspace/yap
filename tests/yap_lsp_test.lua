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
  completion_enable = vim.lsp.completion.enable,
  completion_get = vim.lsp.completion.get,
  executable = vim.fn.executable,
}

local detached = {}
local attached = {}
local notified = {}
local enabled = {}
local requested = {}
local managed_buf
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
vim.lsp.get_clients = function(opts)
  if opts and opts.name == "yap" then
    return opts.bufnr == managed_buf and { fake_client(yap_client_id) } or {}
  end
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

vim.lsp.completion.get = function(opts)
  requested[#requested + 1] = opts.client_id
end
vim.lsp.completion.enable = function(on, id, buf, opts)
  enabled[#enabled + 1] = { on = on, id = id, buf = buf, autotrigger = opts.autotrigger }
end

local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")

-- Defer scheduled callbacks (the setup warm-up and the guard's deferred
-- detach) so the test can flush them deterministically instead of racing
-- the real event loop.
local real_schedule = vim.schedule
local pending = {}
vim.schedule = function(fn)
  pending[#pending + 1] = fn
end
local function flush()
  local q = pending
  pending = {}
  for _, fn in ipairs(q) do
    fn()
  end
end

yap.setup({ bin = ROOT .. "/yap" })

-- 1. a new yap buffer is marked; a pre-attached markdown client is detached
--    (not stopped), and the yap client is attached.
local buf = yap.new({ provider = "mock", model = "m1" })
managed_buf = buf
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
flush()
assert(detached[99] == 1, "LspAttach guard did not detach a late client")
assert(#enabled == 0, "completion enabled for a non-yap client")
vim.api.nvim_exec_autocmds("LspAttach", {
  buffer = buf,
  data = { client_id = yap_client_id },
})
assert(detached[yap_client_id] == nil, "LspAttach guard detached the yap client")
assert(#enabled == 1 and enabled[1].on and enabled[1].id == yap_client_id
  and enabled[1].buf == buf and enabled[1].autotrigger, "Yap autocompletion was not enabled")

-- 3. a non-yap buffer is left alone by the guard.
local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_exec_autocmds("LspAttach", {
  buffer = other,
  data = { client_id = 100 },
})
assert(detached[100] == nil, "LspAttach guard detached a client on a non-yap buffer")
assert(#enabled == 1, "completion enabled on a non-yap buffer")

-- Key completion is requested on typed frontmatter keys, not values or prose.
local function type_at(row, col, text)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { row, col })
  vim.api.nvim_feedkeys("i" .. text, "xt", false)
  local real_mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function() return { mode = "i" } end
  flush()
  vim.api.nvim_get_mode = real_mode
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "prov", "model: foo", "---", "# @user", "hello" })
type_at(2, 3, "i")
assert(#requested == 1 and requested[1] == yap_client_id, "frontmatter key did not request Yap completion")
type_at(3, 9, "i")
type_at(6, 4, "i")
assert(#requested == 1, "completion requested in frontmatter value or prose")

-- Restore the real functions before exit (see the comment at the top of the
-- original test: core vim.lsp's VimLeavePre iterates get_clients()).
vim.lsp.start = real.start
vim.lsp.get_clients = real.get_clients
vim.lsp.get_client_by_id = real.get_client_by_id
vim.lsp.buf_detach_client = real.buf_detach_client
vim.lsp.buf_attach_client = real.buf_attach_client
vim.lsp.buf_is_attached = real.buf_is_attached
vim.lsp.completion.enable = real.completion_enable
vim.lsp.completion.get = real.completion_get
vim.schedule = real_schedule
vim.fn.executable = real.executable

print("yap LSP: completion triggers for sessions and frontmatter keys only")
