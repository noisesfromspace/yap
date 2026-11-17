local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local path = vim.fn.stdpath("cache") .. "/yap/models"
vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
vim.fn.writefile({ "alpha/old" }, path)

local system = vim.system
local callbacks = {}
vim.system = function(cmd, opts, cb)
  if cmd[2] == "models" then
    table.insert(callbacks, cb)
  else
    return system(cmd, opts, cb)
  end
end

-- Let a refresh's vim.schedule callback run so models_refreshing resets
-- before the next discovery is triggered.
local function yield()
  vim.wait(100, function()
    return false
  end)
end

local JSON = '[{"name":"alpha/new"},{"name":"beta/new"}]'

local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })
assert(#callbacks == 1, "setup should refresh models in the background")
local buf = yap.new({ provider = "alpha", model = "old" })
local picked = {}
vim.ui.select = function(items, _, cb)
  table.insert(picked, vim.deepcopy(items))
  cb(items[1])
end

-- The cached list opens immediately, before the async refresh completes.
yap.change_model()
assert(vim.deep_equal(picked[1], { "alpha/old" }), "cached picker should open before refresh completes")

-- `yap models --json` returns one entry per combo; the cache keeps the names.
callbacks[1]({ code = 0, stdout = JSON, stderr = "" })
assert(vim.wait(1000, function()
  return vim.deep_equal(vim.fn.readfile(path), { "alpha/new", "beta/new" })
end))
assert(#picked == 1, "refresh should not reopen the picker")

-- A populated cache still re-runs discovery in the background, so a stale
-- list (a provider that was down when setup() refreshed) self-heals on the
-- next open instead of persisting until Neovim restarts.
yap.change_model()
assert(vim.deep_equal(picked[2], { "alpha/new", "beta/new" }), "next picker should use refreshed list")
assert(#callbacks == 2, "picker with a cache should still refresh in the background")

-- A failed refresh keeps the last good list and its disk cache.
callbacks[2]({ code = 1, stdout = "", stderr = "offline" })
yield()
yap.change_model()
assert(vim.deep_equal(picked[3], { "alpha/new", "beta/new" }), "failure should keep last good list")
assert(vim.deep_equal(vim.fn.readfile(path), { "alpha/new", "beta/new" }), "failure should keep disk cache")
vim.system = system
assert(vim.b[buf].yap_provider == "alpha")
print("OK model cache")
