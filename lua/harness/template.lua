-- Templates and skills: reusable context material inserted into conversation documents.

local M = {}
local document = require("harness.document")
local HEAD = "^# @(%a+)%s*$"

local function config()
  return require("harness").config
end
local function running(buf)
  return require("harness").is_running(buf)
end

-- ─── Templates & skills ────────────────────────────────────────────────────

--- `*.md` files in `dir`, sorted by name; empty when the dir is missing.
local function list_md(dir)
  dir = vim.fs.normalize(dir)
  local out = {}
  for name, type in vim.fs.dir(dir) do
    -- glob("*.md") skips dotfiles; vim.fs.dir does not.
    if type == "file" and name:sub(1, 1) ~= "." and name:match("%.md$") then
      local path = vim.fs.joinpath(dir, name)
      out[#out + 1] = { path = path, name = vim.fn.fnamemodify(path, ":t:r") }
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

--- Split optional YAML frontmatter (`---` ... `---`) off a skill file and
--- return its `description:` key (feeds the intro list) plus the body lines.
local function skill_parts(text)
  local description
  local lines = vim.split(text, "\n", { plain = true })
  if lines[1] and lines[1]:match("^%-%-%-%s*$") then
    local close
    for i = 2, #lines do
      if lines[i]:match("^%-%-%-%s*$") then
        close = i
        break
      end
      local d = lines[i]:match("^description:%s*(.*)%s*$")
      if d then
        description = d
      end
    end
    if close then
      local rest = {}
      for i = close + 1, #lines do
        rest[#rest + 1] = lines[i]
      end
      lines = rest
    end
  end
  return description, lines
end

local function trim_blank(lines)
  while #lines > 0 and lines[1]:match("^%s*$") do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return lines
end

--- All insertable entries: templates first, then skills (picker label
--- prefixed `skill: ` so the two kinds stay distinguishable).
local function template_entries()
  local entries = {}
  for _, t in ipairs(list_md(config().templates_dir)) do
    entries[#entries + 1] = { label = t.name, name = t.name, path = t.path, kind = "template" }
  end
  for _, s in ipairs(list_md(config().skills_dir)) do
    entries[#entries + 1] = { label = "skill: " .. s.name, name = s.name, path = s.path, kind = "skill" }
  end
  return entries
end

--- A template is treated as a native snippet when it uses LSP snippet
--- syntax (`$N` tabstops or `${...}` placeholders).
local function is_snippet(text)
  return text:find("%$[%d{]") ~= nil
end

--- Append a template as a message block: a leading `# @role` heading is
--- used as-is (so a template can be a prefill or raw block); otherwise the
--- text is a `# @user` message. `document.append_message` owns the
--- reuse-the-trailing-heading-or-wrap decision.
function M.append_as_block(buf, lines)
  if #lines == 0 then
    vim.notify("yap: template is empty", vim.log.levels.WARN)
    return
  end
  local role = lines[1]:match(HEAD)
  if role then
    local body = {}
    for i = 2, #lines do
      body[#body + 1] = lines[i]
    end
    document.append_message(buf, role, body)
  else
    document.append_message(buf, "user", lines)
  end
end

--- Append `body` (a message block, no surrounding blank lines) to the end
--- of the buffer as a native snippet: one blank line of separation, cursor
--- left on the first tabstop. `<Tab>`/`<S-Tab>` jump between placeholders
--- and typing over a placeholder replaces it (Neovim's snippet machinery).
function M.append_snippet_block(buf, body)
  local n = vim.api.nvim_buf_line_count(buf)
  local keep = n
  while keep > 1 and vim.api.nvim_buf_get_lines(buf, keep - 1, keep, false)[1] == "" do
    keep = keep - 1
  end
  vim.api.nvim_buf_set_lines(buf, keep, n, false, { "" })
  vim.api.nvim_win_set_cursor(0, { keep + 1, 0 })
  vim.snippet.expand("\n" .. body)
end

--- Insert `body` as a snippet above the cursor's line (the raw primitive
--- behind :YapInsertHere).
function M.insert_snippet_at_cursor(buf, body)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
  vim.snippet.expand(body .. "\n")
end

--- Merge a skill's body into the buffer's `# @system` block (or create the
--- block at the top when there is none). Skills are system-prompt material:
--- they go where a stateless provider keeps instructions.
local function merge_into_system(buf, lines)
  if #lines == 0 then
    vim.notify("yap: skill is empty", vim.log.levels.WARN)
    return
  end
  local blines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local sys
  for i, l in ipairs(blines) do
    if l:match("^# @system%s*$") then
      sys = i
      break
    end
  end
  if not sys then
    local top = { "# @system", "" }
    vim.list_extend(top, lines)
    top[#top + 1] = ""
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, top)
    return
  end
  local next_head = #blines + 1
  for i = sys + 1, #blines do
    if blines[i]:match(HEAD) then
      next_head = i
      break
    end
  end
  local body_end = next_head - 1
  while body_end > sys and blines[body_end]:match("^%s*$") do
    body_end = body_end - 1
  end
  local ins = {}
  if body_end > sys then
    ins[#ins + 1] = ""
  end
  vim.list_extend(ins, lines)
  ins[#ins + 1] = ""
  vim.api.nvim_buf_set_lines(buf, next_head - 1, next_head - 1, false, ins)
end

--- Insert `lines` as new lines above the cursor's line (the raw primitive).
local function insert_at_cursor(buf, lines)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  vim.api.nvim_buf_set_lines(buf, row, row, false, vim.deepcopy(lines))
end

--- Skills intro for new chats: a short `## Skills` list (name + frontmatter
--- description) in the system block — discoverability, not auto-load.
--- Returns nil when there are no skills.
function M.skills_intro_lines()
  local lines = {}
  for _, s in ipairs(list_md(config().skills_dir)) do
    local text = read_file(s.path)
    if text then
      local description = skill_parts(text)
      lines[#lines + 1] = "- " .. s.name .. (description and (": " .. description) or "")
    end
  end
  return #lines > 0 and lines or nil
end

--- :YapInsert [name] / :YapInsertHere [name].
--- `opts.at_cursor` (default false) inserts verbatim above the cursor;
--- otherwise a template appends as a message block and a skill merges into
--- the system block. While the agent is mid-turn a template steers the
--- running turn (injected at the next tool boundary) instead of inserting;
--- skills and at-cursor inserts still refuse. With no name, pick from the
--- combined list.
function M.insert(name, opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  if not vim.b[buf].yap then
    vim.notify("yap: not a yap buffer", vim.log.levels.WARN)
    return
  end

  local function apply(entry)
    local text = read_file(entry.path)
    if not text then
      vim.notify("yap: cannot read " .. entry.path, vim.log.levels.ERROR)
      return
    end
    local lines
    if entry.kind == "skill" then
      _, lines = skill_parts(text)
    else
      lines = vim.split(text, "\n", { plain = true })
    end
    lines = trim_blank(lines)
    if running(buf) then
      -- Mid-turn a template steers the running turn instead of editing the
      -- streaming buffer; skills and raw cursor inserts still refuse.
      if entry.kind ~= "template" or opts.at_cursor then
        vim.notify("yap: turn running; stop it before inserting a skill or editing the buffer", vim.log.levels.WARN)
        return
      end
      -- Steering is always a `# @user` injection, so a leading role
      -- heading is stripped and the body is the steering text.
      if lines[1] and lines[1]:match(HEAD) then
        local body = {}
        for i = 2, #lines do
          body[#body + 1] = lines[i]
        end
        lines = trim_blank(body)
      end
      require("harness").steer(buf, table.concat(lines, "\n"))
      return
    end
    if entry.kind ~= "skill" and is_snippet(table.concat(lines, "\n")) then
      -- Native snippet: expand placeholders/tabstops instead of plain text.
      local body = table.concat(lines, "\n")
      if opts.at_cursor then
        M.insert_snippet_at_cursor(buf, body)
      else
        -- Same reuse decision as append_message: an unheaded snippet fills
        -- the trailing `# @user` block instead of adding a second heading.
        if not lines[1]:match(HEAD) and document.trailing_role(buf) ~= "user" then
          body = "# @user\n\n" .. body
        end
        M.append_snippet_block(buf, body)
      end
    elseif opts.at_cursor then
      insert_at_cursor(buf, lines)
    elseif entry.kind == "skill" then
      merge_into_system(buf, lines)
    else
      M.append_as_block(buf, lines)
    end
  end

  local entries = template_entries()
  if name then
    for _, e in ipairs(entries) do
      if e.name == name then
        apply(e)
        return
      end
    end
    vim.notify("yap: no template/skill named: " .. name, vim.log.levels.WARN)
    return
  end
  if #entries == 0 then
    vim.notify("yap: no templates or skills in " .. config().templates_dir .. " or " .. config().skills_dir,
      vim.log.levels.INFO)
    return
  end
  local items = {}
  for _, e in ipairs(entries) do
    items[#items + 1] = e.label
  end
  vim.ui.select(items, { prompt = "yap insert" }, function(choice)
    if not choice then
      return
    end
    for _, e in ipairs(entries) do
      if e.label == choice then
        apply(e)
        return
      end
    end
  end)
end

--- Completion list for :YapInsert / :YapInsertHere.
function M.template_names()
  local names = {}
  for _, e in ipairs(template_entries()) do
    names[#names + 1] = e.name
  end
  return names
end

function M.named_lines(name)
  for _, entry in ipairs(list_md(config().templates_dir)) do
    if entry.name == name then
      local text = read_file(entry.path)
      if text then
        return trim_blank(vim.split(text, "\n", { plain = true }))
      end
    end
  end
end

return M
