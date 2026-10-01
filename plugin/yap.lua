if vim.g.loaded_yap then
  return
end
vim.g.loaded_yap = true

vim.api.nvim_create_user_command("Yap", function()
  require("harness").new()
end, { desc = "Open a new yap chat buffer" })

vim.api.nvim_create_user_command("YapSend", function()
  require("harness").send()
end, { desc = "Send the buffer to the model" })

vim.api.nvim_create_user_command("YapStop", function()
  require("harness").stop()
end, { desc = "Stop the in-flight yap request" })

vim.api.nvim_create_user_command("YapLive", function()
  require("harness").live()
end, { desc = "Open the session's live tool-output view" })

vim.api.nvim_create_user_command("YapClear", function(cmd)
  require("harness").clear(0, tonumber(cmd.args))
end, {
  nargs = "?",
  desc = "Clear old tool results from the context (full output stays in the audit log); arg: how many to keep (default 2)",
})

vim.api.nvim_create_user_command("YapCompact", function()
  require("harness").compact()
end, {
  desc = "Summarize the conversation into a compact context: insert the compact prompt, send, then offer to delete the superseded history",
})

vim.api.nvim_create_user_command("YapInsert", function(cmd)
  require("harness").insert(cmd.fargs[1], {})
end, {
  nargs = "?",
  complete = function()
    return require("harness").template_names()
  end,
  desc = "Insert a template (as a # @user block) or skill (into the system prompt); arg: name, or pick from the list",
})

vim.api.nvim_create_user_command("YapInsertHere", function(cmd)
  require("harness").insert(cmd.fargs[1], { at_cursor = true })
end, {
  nargs = "?",
  complete = function()
    return require("harness").template_names()
  end,
  desc = "Insert a template or skill verbatim above the cursor",
})

vim.api.nvim_create_user_command("YapChangeModel", function(cmd)
  require("harness").change_model(cmd.fargs[1])
end, {
  nargs = "?",
  complete = function()
    return require("harness").config.models or {}
  end,
  desc = "Change the provider/model combo for the current buffer (no arg: pick from configured models)",
})

vim.api.nvim_create_user_command("YapReload", function()
  local old_config = require("harness").config
  package.loaded.harness = nil
  package.loaded["harness.session"] = nil
  package.loaded["harness.fold"] = nil
  package.loaded["harness.frontmatter"] = nil
  require("harness").setup(old_config)
  local src = debug.getinfo(require("harness").send, "S").source:sub(2)
  vim.notify("yap: reloaded from " .. src)
end, { desc = "Reload the yap Lua module (development)" })

vim.api.nvim_create_user_command("YapSessions", function(cmd)
  require("harness").sessions(cmd.fargs[1])
end, {
  nargs = "?",
  complete = function()
    return { "all" }
  end,
  desc = "Pick a saved yap session to resume (:YapSessions all for every project)",
})

vim.api.nvim_create_user_command("YapInstances", function()
  require("harness").instances()
end, { desc = "List open yap sessions with status and jump to the picked one" })
