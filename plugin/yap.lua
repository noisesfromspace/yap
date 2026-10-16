if vim.g.loaded_yap then
  return
end
vim.g.loaded_yap = true

vim.api.nvim_create_user_command("Yap", function()
  require("harness").new()
end, { desc = "Open a new yap session buffer" })

vim.api.nvim_create_user_command("YapSend", function()
  require("harness").send()
end, { desc = "Send the buffer to the model" })

vim.api.nvim_create_user_command("YapStop", function()
  require("harness").stop()
end, { desc = "Stop the in-flight yap request" })

vim.api.nvim_create_user_command("YapLive", function()
  require("harness").live()
end, { desc = "Open the session's live tool tail" })

vim.api.nvim_create_user_command("YapGuard", function()
  require("harness.guard").toggle()
end, { desc = "Open the guard board: pending approvals, advisories and history" })

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

vim.api.nvim_create_user_command("YapEval", function(cmd)
  require("harness").eval({ line1 = cmd.line1, line2 = cmd.line2, instruction = cmd.args })
end, {
  range = true,
  nargs = "?",
  desc = "Replace the selected lines with the model's output (one-shot, no tools)",
})

vim.api.nvim_create_user_command("YapInsert", function(cmd)
  require("harness").insert(cmd.fargs[1], {})
end, {
  nargs = "?",
  complete = function()
    return require("harness").template_names()
  end,
  desc = "Insert a template (as a `# @user` message) or skill (into the system prompt); arg: name, or pick from the list",
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

vim.api.nvim_create_user_command("YapFork", function(cmd)
  local path, err = require("harness").fork(cmd.args)
  if not path then
    vim.notify("yap: " .. err, vim.log.levels.WARN)
  end
end, {
  nargs = "?",
  desc = "Copy this conversation into a new independent session and open it",
})

vim.api.nvim_create_user_command("YapSessions", function(cmd)
  require("harness").sessions(cmd.fargs[1])
end, {
  nargs = "?",
  complete = function()
    return { "all" }
  end,
  desc = "Pick a saved yap session to resume (:YapSessions all for every project)",
})
