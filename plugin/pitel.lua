if vim.g.loaded_pitel then
  return
end
vim.g.loaded_pitel = true

vim.api.nvim_create_user_command("Pitel", function()
  require("pitel").new()
end, { desc = "Open a new pitel chat buffer" })

vim.api.nvim_create_user_command("PitelSend", function()
  require("pitel").send()
end, { desc = "Send the buffer to the model" })

vim.api.nvim_create_user_command("PitelStop", function()
  require("pitel").stop()
end, { desc = "Stop the in-flight pitel request" })

vim.api.nvim_create_user_command("PitelReload", function()
  local old_config = require("pitel").config
  package.loaded.pitel = nil
  package.loaded["pitel.session"] = nil
  package.loaded["pitel.fold"] = nil
  require("pitel").setup(old_config)
  local src = debug.getinfo(require("pitel").send, "S").source:sub(2)
  vim.notify("pitel: reloaded from " .. src)
end, { desc = "Reload the pitel Lua module (development)" })

vim.api.nvim_create_user_command("PitelSessions", function(cmd)
  require("pitel").sessions(cmd.fargs[1])
end, {
  nargs = "?",
  complete = function()
    return { "all" }
  end,
  desc = "Pick a saved pitel session to resume (:PitelSessions all for every project)",
})
