-- Shared structural parser for folding and navigation.
-- Extracted from harness.ui.fold

local M = {}

local HEAD = "^# @(%a+)%s*$"
local TOOL_OPEN = "^<!%-%- yap:tool"
local TOOL_CLOSE = "^<!%-%- /yap:tool"
local COMMENT_OPEN = "^<!%-%-.*yap:%a+%s*$"
-- Any yap marker opener or closer line: `<!-- yap:...` or `<!-- /yap:...`.
local MARKER_LINE = "^<!%-%- /?yap:"

-- fence_run: a fence opener/closer — <=3 spaces indent then a run of
-- >=3 backticks or tildes. Returns (char, run, tail) or nil. Indent is
-- spaces only (CommonMark: a tab advances to the next tab stop, so a
-- tab-indented fence is indented beyond 3 and is not a fence).
local function fence_run(line)
  local ws = line:match("^ *")
  if #ws > 3 then
    return nil
  end
  local rest = line:sub(#ws + 1)
  local c = rest:sub(1, 1)
  if c ~= "`" and c ~= "~" then
    return nil
  end
  local n = 0
  while rest:sub(n + 1, n + 1) == c do
    n = n + 1
  end
  if n < 3 then
    return nil
  end
  local tail = rest:sub(n + 1)
  -- CommonMark: a backtick fence's info string cannot contain a backtick;
  -- a tilde fence's cannot contain a backtick or a tilde. Such a line is
  -- content, not a fence (kept in sync with Go's render.fenceLine via
  -- tests/fence_cases.json).
  if c == "`" and tail:find("`", 1, true) then
    return nil
  end
  if c == "~" and (tail:find("`", 1, true) or tail:find("~", 1, true)) then
    return nil
  end
  return c, n, tail
end

-- One O(n) forward pass over the buffer produces the structural units the
-- three views fold. Fences and multi-line HTML comments are tracked so a
-- fake `# @user` inside a fenced tool result, or a `-->` inside a fence,
-- can't split the structure. This mirrors the old classify() state machine
-- but emits fold ranges instead of per-line level strings.
--
--   headings = { {role="system"|"user"|"assistant", line}, … }  (in order)
--   regions  = { {kind="tool"|"thinking"|"error"|…, start, finish}, … }
--              finish is nil while a region is still open (streaming).
--
-- The scanner keeps its mutable state (open fence/comment/tool region) in a
-- `ctx` table so a pure tail append can resume from a checkpoint instead of
-- rescanning the whole buffer (R-stream-parse): a streaming reply appends to
-- the last line, which never shifts existing line numbers, so the only work
-- is re-classifying the tail.
local model_cache = {} -- buf -> { tick, parse, ctx, checkpoint, tail_clean }

local function new_ctx()
  return {
    headings = {},
    regions = {},
    region = nil, -- "tool" while a yap:tool region is open, else nil
    fence = nil, -- { char, n } while inside a fenced code block
    comment = nil, -- { kind, region? } while inside a multi-line marker
    comment_i = nil, -- index of comment.region in regions (or nil)
    tool = nil, -- the open yap:tool region table (an element of regions)
    tool_i = nil, -- index of tool in regions (or nil)
  }
end

local function end_tool(ctx, finish)
  if ctx.tool and not ctx.tool.finish then
    ctx.tool.finish = finish
  end
  ctx.tool = nil
  ctx.tool_i = nil
end

-- One line of the forward pass.
local function step(ctx, i, line)
  if ctx.fence then
    local c, n, tail = fence_run(line)
    if c == ctx.fence.char and n >= ctx.fence.n and tail:match("^%s*$") then
      ctx.fence = nil
    end
  elseif ctx.comment then
    -- Inside a multi-line HTML comment: raw text until a bare `-->`
    -- (a ``` inside a comment is NOT a fence). An unclosed comment
    -- (thinking/error) must not swallow the next message boundary: bound
    -- it at the next `# @role` heading, mirroring how tool regions stop
    -- at a heading. tool_inner comments (multi-line JSON headers) always
    -- close with `-->` and are left alone.
    if line:match("^%-%->%s*$") then
      if ctx.comment.region then
        ctx.comment.region.finish = i
      end
      ctx.comment = nil
      ctx.comment_i = nil
    elseif ctx.comment.region and line:match(HEAD) then
      ctx.comment.region.finish = i - 1
      ctx.comment = nil
      ctx.comment_i = nil
      ctx.headings[#ctx.headings + 1] = { role = line:match(HEAD), line = i }
    end
  else
    local c, n = fence_run(line)
    if c then
      ctx.fence = { char = c, n = n }
    elseif line:match(HEAD) then
      -- A heading ends an unfinished tool region; document.lua still
      -- treats headings inside well-formed tool results as result text.
      end_tool(ctx, i - 1)
      ctx.headings[#ctx.headings + 1] = { role = line:match(HEAD), line = i }
      ctx.region = nil
    elseif line:match(TOOL_OPEN) and ctx.region ~= "tool" then
      end_tool(ctx, i - 1)
      local d = { kind = "tool", start = i }
      ctx.regions[#ctx.regions + 1] = d
      ctx.tool, ctx.tool_i = d, #ctx.regions
      ctx.region = "tool"
      -- Pretty JSON headers are comments too: fence/heading-looking
      -- argument lines must not change the surrounding region structure.
      if not line:find("-->", 1, true) then
        ctx.comment = { kind = "tool_inner" }
        ctx.comment_i = nil
      end
    elseif line:match(COMMENT_OPEN) and not line:match("%-%->") then
      local kind = line:match("yap:(%a+)") or "comment"
      local d = { kind = kind, start = i }
      ctx.regions[#ctx.regions + 1] = d
      ctx.comment = { kind = kind, region = d }
      ctx.comment_i = #ctx.regions
    elseif line:match(TOOL_CLOSE) then
      end_tool(ctx, i)
      ctx.region = nil
    end
    -- else: plain content line
  end
end

-- O(1) snapshot of the scanner state just before the last scanned line.
-- References into `regions` are stored as indices (plus their current
-- finish) so a tail append can truncate the result and re-point them.
local function snapshot(ctx)
  return {
    headings_n = #ctx.headings,
    regions_n = #ctx.regions,
    region = ctx.region,
    fence = ctx.fence and { char = ctx.fence.char, n = ctx.fence.n } or nil,
    comment_kind = ctx.comment and ctx.comment.kind or nil,
    comment_i = ctx.comment and ctx.comment_i or nil,
    comment_finish = ctx.comment and ctx.comment.region and ctx.comment.region.finish or nil,
    tool_i = ctx.tool_i,
    tool_finish = ctx.tool and ctx.tool.finish or nil,
  }
end

local function restore(ctx, cp)
  for i = #ctx.headings, cp.headings_n + 1, -1 do
    ctx.headings[i] = nil
  end
  for i = #ctx.regions, cp.regions_n + 1, -1 do
    ctx.regions[i] = nil
  end
  ctx.region = cp.region
  ctx.fence = cp.fence
  if cp.comment_kind then
    ctx.comment = { kind = cp.comment_kind }
    ctx.comment_i = cp.comment_i
    if cp.comment_i then
      ctx.comment.region = ctx.regions[cp.comment_i]
      ctx.comment.region.finish = cp.comment_finish
    end
  else
    ctx.comment = nil
    ctx.comment_i = nil
  end
  if cp.tool_i then
    ctx.tool = ctx.regions[cp.tool_i]
    ctx.tool.finish = cp.tool_finish
    ctx.tool_i = cp.tool_i
  else
    ctx.tool = nil
    ctx.tool_i = nil
  end
end

local function parse(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local cached = model_cache[buf]
  if cached and cached.tick == tick then
    return cached.parse
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- YAML frontmatter (`---` ... `---`) precedes the first heading. Fold it
  -- as its own unit so session options can collapse in views 1 and 2.
  local frontmatter
  if lines[1] and lines[1]:match("^%-%-%-%s*$") then
    for i = 2, #lines do
      if lines[i]:match("^%-%-%-%s*$") then
        frontmatter = i
        break
      end
    end
  end
  local ctx = new_ctx()
  local checkpoint
  for i, line in ipairs(lines) do
    if i == #lines then
      checkpoint = snapshot(ctx)
    end
    step(ctx, i, line)
  end

  local p = { headings = ctx.headings, regions = ctx.regions, count = #lines, frontmatter = frontmatter }
  model_cache[buf] = { tick = tick, parse = p, ctx = ctx, checkpoint = checkpoint, tail_clean = true }
  return p
end

-- Extend a cached parse for a pure tail append (append_text). Rewinds to the
-- checkpoint captured just before the previous last line and rescans only the
-- new tail. The caller marks non-tail edits via M.mark_changed; when that
-- flag is off (or the buffer shrank) this falls back to a full rescan, so a
-- mis-classified change is never silently mis-parsed.
local function extend(buf)
  local cached = model_cache[buf]
  if not cached or not cached.ctx or not cached.checkpoint or not cached.tail_clean then
    return parse(buf)
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if cached.tick == tick then
    return cached.parse
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines < cached.parse.count then
    return parse(buf)
  end
  local ctx = cached.ctx
  restore(ctx, cached.checkpoint)
  local checkpoint
  for i = cached.parse.count, #lines do
    if i == #lines then
      checkpoint = snapshot(ctx)
    end
    step(ctx, i, lines[i])
  end
  local p = { headings = ctx.headings, regions = ctx.regions, count = #lines, frontmatter = cached.parse.frontmatter }
  cached.parse = p
  cached.tick = tick
  cached.checkpoint = checkpoint
  cached.tail_clean = true
  return p
end

-- Record a buffer edit so extend() only trusts a checkpoint while every edit
-- since the last parse touched only the tail (the last line or beyond).
-- `firstline` is the 0-based index of the first OLD line the edit replaced.
function M.mark_changed(buf, firstline)
  local c = model_cache[buf]
  if not c then
    return
  end
  if type(firstline) ~= "number" then
    c.tail_clean = false -- unknown edit shape: be conservative, rescan
  else
    c.tail_clean = c.tail_clean and (firstline >= c.parse.count - 1)
  end
end

function M.parse(buf)
  return parse(buf)
end

function M.extend(buf)
  return extend(buf)
end

function M.clear(buf)
  model_cache[buf] = nil
end

--- Strip `<!-- yap:* -->` marker regions (thinking/model/error/ui) from raw
--- text, keeping all other lines — including ordinary HTML comments — intact.
--- A single-line marker (ends in `-->`) is dropped; a multi-line marker opens
--- on its own line and is dropped through its bare `-->` closer. This is the
--- raw-output counterpart of document.lua's buffer parser, which drops the
--- same markers while splitting a buffer into messages; eval.lua uses it to
--- clean one-shot `yap send` responses.
function M.strip_markers(text)
  local out = {}
  local in_marker = false
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if in_marker then
      if line == "-->" then
        in_marker = false
      end
    elseif line:match(MARKER_LINE) then
      if not line:match("%-%->%s*$") then
        in_marker = true
      end
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

M.HEAD = HEAD
M.TOOL_OPEN = TOOL_OPEN
M.TOOL_CLOSE = TOOL_CLOSE
M.COMMENT_OPEN = COMMENT_OPEN
M.MARKER_LINE = MARKER_LINE
M.fence_run = fence_run

return M
