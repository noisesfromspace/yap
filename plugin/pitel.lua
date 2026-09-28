if vim.g.loaded_pitel then
  return
end
vim.g.loaded_pitel = true

vim.api.nvim_create_user_command("Pitel", function()
  require("harness").new()
end, { desc = "Open a new pitel chat buffer" })

vim.api.nvim_create_user_command("PitelSend", function()
  require("harness").send()
end, { desc = "Send the buffer to the model" })

vim.api.nvim_create_user_command("PitelStop", function()
  require("harness").stop()
end, { desc = "Stop the in-flight pitel request" })

vim.api.nvim_create_user_command("PitelLive", function()
  require("harness").live()
end, { desc = "Open a terminal tailing the running tool's log" })

vim.api.nvim_create_user_command("PitelChangeModel", function(cmd)
  require("harness").change_model(cmd.fargs[1])
end, {
  nargs = "?",
  complete = function()
    return require("harness").config.models or {}
  end,
  desc = "Change the provider/model combo for the current buffer (no arg: pick from configured models)",
})

vim.api.nvim_create_user_command("PitelReload", function()
  local old_config = require("harness").config
  package.loaded.harness = nil
  package.loaded["harness.session"] = nil
  package.loaded["harness.fold"] = nil
  require("harness").setup(old_config)
  local src = debug.getinfo(require("harness").send, "S").source:sub(2)
  vim.notify("pitel: reloaded from " .. src)
end, { desc = "Reload the pitel Lua module (development)" })

vim.api.nvim_create_user_command("PitelSessions", function(cmd)
  require("harness").sessions(cmd.fargs[1])
end, {
  nargs = "?",
  complete = function()
    return { "all" }
  end,
  desc = "Pick a saved pitel session to resume (:PitelSessions all for every project)",
})
