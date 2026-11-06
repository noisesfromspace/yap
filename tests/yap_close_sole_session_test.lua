-- A close_session turn must actually wipe a session even when it is the
-- only buffer in the editor. Neovim silently retains a deleted sole buffer.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })
local buf = yap.new()
for _, other in ipairs(vim.api.nvim_list_bufs()) do
  if other ~= buf and vim.api.nvim_buf_is_valid(other) then
    vim.api.nvim_buf_delete(other, { force = true })
  end
end
local path = vim.b[buf].yap_path
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
for i = #lines, 1, -1 do
  if lines[i] == "# @user" then
    vim.api.nvim_buf_set_lines(buf, i, -1, false, { "when you are done, close the session" })
    break
  end
end
yap.send(buf)
assert(
  vim.wait(30000, function()
    return not vim.api.nvim_buf_is_valid(buf)
  end, 50),
  "close_session kept the sole session buffer alive"
)
local replacement = vim.api.nvim_get_current_buf()
assert(replacement ~= buf and not vim.b[replacement].yap, "no ordinary replacement buffer")
assert(vim.fn.filereadable(path) == 1, "closed session transcript lost")
local saved = table.concat(vim.fn.readfile(path), "\n")
assert(
  saved:find("Done. Closing.", 1, true) and saved:find("close_session", 1, true),
  "session was not saved before close"
)
print("OK close sole session")
