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

-- Roles the completion menu can auto-select over a bare `# @` shorthand.
local ROLES = { user = true, assistant = true, system = true }

local function role_for(line)
  return SHORTHAND[line]
end

--- Install the buffer-local shorthand trigger for a managed session buffer.
function M.setup_buffer(buf)
  -- True while the user has typed a bare `# @` and no role letter yet. The
  -- role completion's auto-select (completeopt without `noselect`) rewrites
  -- the line to `# @assistant` asynchronously, so the line alone cannot tell
  -- a bare shorthand apart from a typed-out heading; the keystroke history can.
  local bare = false

  vim.api.nvim_create_autocmd("InsertCharPre", {
    buffer = buf,
    callback = function()
      local char = vim.v.char
      local line = vim.api.nvim_get_current_line()
      if char == "@" then
        -- The `@` that turns `# ` into `# @` opens a bare shorthand; any
        -- other `@` (file references) does not.
        bare = line == "# "
        return
      end
      if char == " " then
        local cursor = vim.api.nvim_win_get_cursor(0)
        local row, col = cursor[1], cursor[2]
        local role
        if col == #line then
          role = role_for(line)
          if not role and bare then
            -- The completion auto-selected a role over the bare shorthand.
            -- Space would commit it; expand to the shorthand's default instead.
            -- Only a whole role heading qualifies, so a `# @path` file
            -- completion or a typed-out heading is untouched.
            local r = line:match("^# @([a-z]+)$")
            if r and ROLES[r] then
              role = "user"
            end
          end
        end
        bare = false
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
          -- The space may or may not land (the menu may commit the selection
          -- without inserting it), so accept the line either way.
          if now ~= line and now ~= line .. " " then
            return
          end
          -- Heading, blank line, empty body. The cursor lands on the body line.
          vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, #now, { "# @" .. role, "", "" })
          vim.api.nvim_win_set_cursor(0, { row + 2, 0 })
        end)
        return
      end
      -- Any other character (a role letter, prose, punctuation, editing)
      -- ends the bare state; a letter shorthand is handled by the line
      -- content itself at the next space.
      bare = false
    end,
  })
end

return M
