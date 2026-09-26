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

vim.api.nvim_create_user_command("PitelUse", function(cmd)
  require("pitel").use(cmd.fargs[1], cmd.fargs[2])
end, {
  nargs = "+",
  desc = "Switch provider/model for this buffer: :PitelUse {provider} {model}",
})
