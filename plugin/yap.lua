if vim.g.loaded_yap then
  return
end
vim.g.loaded_yap = true

vim.api.nvim_create_user_command("Yap", function(cmd)
  local opts = {}
  local arg = cmd.args and vim.trim(cmd.args) or ""
  if arg ~= "" then
    -- A transcript anywhere: `:Yap path/to/file.md` opens the session at
    -- that file, `:Yap path/to/dir` drops `session.md` inside it. Everything
    -- resolves against the project cwd, so a bare filename lands beside the
    -- files being discussed, not in yap's data root.
    if arg:sub(1, 1) == "~" then
      arg = vim.env.HOME .. arg:sub(2)
    end
    local path = vim.fn.fnamemodify(arg, ":p")
    if vim.fn.isdirectory(path) == 1 then
      path = vim.fs.joinpath(path, "session.md")
    elseif not path:match("%.md$") then
      path = path .. ".md"
    end
    -- An existing transcript is opened, never replaced: a moved session.md
    -- resumes its conversation (frontmatter data_dir still ties it to its
    -- audit log and assets) instead of being clobbered by a fresh template.
    if vim.fn.filereadable(path) == 1 then
      require("harness").open(path)
      return
    end
    opts.path = path
  end
  require("harness").new(opts)
end, { nargs = "?", desc = "Open a new yap session buffer (optional transcript path)" })

vim.api.nvim_create_user_command("YapClear", function(cmd)
  require("harness").clear(0, tonumber(cmd.args))
end, {
  nargs = "?",
  desc = "Clear old tool results from the context (full output stays in the audit log); arg: how many to keep (default 2)",
})

vim.api.nvim_create_user_command("YapCompact", function(cmd)
  require("harness").compact(cmd.args)
end, {
  nargs = "*",
  desc = "Summarize the conversation with optional custom instructions, then offer to delete the superseded history",
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
