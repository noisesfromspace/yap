-- Role-heading shorthand. Typing `# @`, `# @a` or `# @s` followed by a space
-- expands to a full `# @<role>` heading with a blank line and the cursor in
-- the body. This is the fast path for starting a message; the LSP role
-- completion (triggered by the `@` itself) stays available for the bare
-- `# @` case as the fallback. No completion or structural rule lives here
-- (R-language-intelligence): the snippet is a plain buffer edit, like the
-- text objects and motions that also stay in Lua.

local M = {}

-- The role a shorthand line expands to, or nil. `# @` is the user default;
-- `# @a` and `# @s` name assistant and system. Matching the whole line (not
-- a prefix) keeps a fully typed `# @assistant` / `# @system` from collapsing.
local SHORTHAND = {
  ["# @"] = "user",
  ["# @a"] = "assistant",
  ["# @s"] = "system",
}

local function role_for(line)
  return SHORTHAND[line]
end

--- Install the buffer-local shorthand trigger for a managed session buffer.
function M.setup_buffer(buf)
  vim.api.nvim_create_autocmd("InsertCharPre", {
    buffer = buf,
    callback = function()
      if vim.v.char ~= " " then
        return
      end
      local line = vim.api.nvim_get_current_line()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      if col ~= #line then
        return
      end
      local role = role_for(line)
      if not role then
        return
      end
      -- InsertCharPre fires before the space lands and may not edit the
      -- buffer (E565), so defer: the space is inserted, then the whole
      -- shorthand line is replaced by the expanded heading.
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_get_current_buf() ~= buf then
          return
        end
        local now = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
        if now ~= line .. " " then
          return
        end
        -- Heading, blank line, empty body. The cursor lands on the body line.
        vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, #now, { "# @" .. role, "", "" })
        vim.api.nvim_win_set_cursor(0, { row + 2, 0 })
      end)
    end,
  })
end

return M
