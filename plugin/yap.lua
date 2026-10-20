if vim.g.loaded_yap then
  return
end
vim.g.loaded_yap = true

vim.api.nvim_create_user_command("Yap", function()
  require("harness").new()
end, { desc = "Open a new yap session buffer" })

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
  local opts = { instruction = cmd.args }
  -- range == 0 means no range was given: generate at the cursor instead of
  -- replacing a selection.
  if cmd.range > 0 then
    opts.line1 = cmd.line1
    opts.line2 = cmd.line2
  end
  if cmd.bang then
    require("harness").eval(opts)
  else
    require("harness").eval_session(opts)
  end
end, {
  range = true,
  nargs = "?",
  bang = true,
  desc = "Discuss the selection in a hidden eval session; ! replaces it with the model's output (one-shot, no tools)",
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
