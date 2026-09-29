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

vim.api.nvim_create_user_command("PitelClear", function(cmd)
  require("harness").clear(0, tonumber(cmd.args))
end, {
  nargs = "?",
  desc = "Clear old tool results from the context (full output stays in the audit log); arg: how many to keep (default 2)",
})

vim.api.nvim_create_user_command("PitelCompact", function()
  require("harness").compact()
end, {
  desc = "Summarize the conversation into a compact context: insert the compact prompt, send, then offer to delete the superseded history",
})

vim.api.nvim_create_user_command("PitelInsert", function(cmd)
  require("harness").insert(cmd.fargs[1], {})
end, {
  nargs = "?",
  complete = function()
    return require("harness").template_names()
  end,
  desc = "Insert a template (as a # @user block) or skill (into the system prompt); arg: name, or pick from the list",
})

vim.api.nvim_create_user_command("PitelInsertHere", function(cmd)
  require("harness").insert(cmd.fargs[1], { at_cursor = true })
end, {
  nargs = "?",
  complete = function()
    return require("harness").template_names()
  end,
  desc = "Insert a template or skill verbatim above the cursor",
})

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
  package.loaded["harness.frontmatter"] = nil
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

vim.api.nvim_create_user_command("PitelWaiting", function()
  require("harness").waiting()
end, { desc = "List agents waiting for a reply and jump to the picked one" })

vim.api.nvim_create_user_command("PitelInstances", function()
  require("harness").instances()
end, { desc = "List open pitel sessions by file path and jump to the picked one" })
