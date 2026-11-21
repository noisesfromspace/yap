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
--   events   = { {line, kind, outcome?, ts?, assistant?}, … } (in order)
--   guard_decisions = { {line, tool_start, outcome, ts}, … } (in order)
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
    events = {},
    guard_decisions = {},
    tool_durations = {},
    tool_outcomes = {},
    guard_tool = nil, -- start of the just-closed tool, before any other content
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

-- Open a yap:tool region at line i. A single-line header closes on the same
-- line; the multi-line form (`<!-- yap:tool` … JSON … `-->`) is a comment
-- until that `-->`.
local function open_tool(ctx, i, line)
  local d = { kind = "tool", start = i }
  ctx.regions[#ctx.regions + 1] = d
  ctx.tool, ctx.tool_i = d, #ctx.regions
  ctx.region = "tool"
  if line:find("-->", 1, true) then
    d.header_finish = i
  else
    ctx.comment = { kind = "tool_inner" }
    ctx.comment_i = nil
  end
end

-- One line of the forward pass.
local function step(ctx, i, line)
  local json = line:match("^<!%-%- yap:event (.-) %-%->%s*$")
  if json and not ctx.fence and not ctx.comment and not ctx.tool then
    local ok, ev = pcall(vim.json.decode, json)
    if ok and type(ev) == "table" and type(ev.type) == "string" then
      local ts = type(ev.ts) == "string" and ev.ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d") or nil
      if ev.type == "guard_decision" and type(ev.outcome) == "string" then
        -- A guard decision trails its tool's closer. Keep the tool armed so a
        -- run of consecutive decisions all share it.
        ctx.guard_decisions[#ctx.guard_decisions + 1] = {
          line = i,
          tool_start = ctx.guard_tool,
          outcome = ev.outcome,
          ts = ts,
        }
      elseif ev.type == "tool_duration" and type(ev.ms) == "number" then
        -- A long bash call records its duration right after its tool result.
        ctx.tool_durations[#ctx.tool_durations + 1] = {
          line = i,
          tool_start = ctx.guard_tool,
          ms = ev.ms,
        }
      elseif ev.type == "tool_outcome" and type(ev.outcome) == "string" then
        -- An abnormal result (error, timeout, nonzero exit) trails its tool's
        -- closer, like a guard decision or a duration.
        ctx.tool_outcomes[#ctx.tool_outcomes + 1] = {
          line = i,
          tool_start = ctx.guard_tool,
          outcome = ev.outcome,
          code = type(ev.code) == "number" and ev.code or nil,
        }
      else
        ctx.events[#ctx.events + 1] = { line = i, kind = ev.type, outcome = ev.outcome, ts = ts }
        ctx.guard_tool = nil -- a non-guard event breaks the trailing run
      end
      return
    end
  end
  if ctx.guard_tool and not line:match("^%s*$") then
    ctx.guard_tool = nil
  end
  if ctx.fence then
    local c, n, tail = fence_run(line)
    if c == ctx.fence.char and n >= ctx.fence.n and tail:match("^%s*$") then
      ctx.fence = nil
    end
  elseif ctx.comment then
    -- Inside a multi-line HTML comment: raw text until a bare `-->`
    -- (a ``` inside a comment is NOT a fence). An unclosed comment
    -- (thinking/error) must not swallow the next message boundary: bound
    -- it at the next `# @role` heading, mirroring how an unclosed tool
    -- region is bounded below.
    if line:match("^%-%->%s*$") then
      if ctx.comment.region then
        ctx.comment.region.finish = i
      elseif ctx.tool then
        -- A multi-line tool header closes here; everything below is result.
        ctx.tool.header_finish = i
      end
      ctx.comment = nil
      ctx.comment_i = nil
    elseif line:match(HEAD) then
      if ctx.tool then
        -- An unterminated multi-line header is malformed: bound the region
        -- here so it cannot swallow the rest of the conversation.
        end_tool(ctx, i - 1)
        ctx.region = nil
      else
        ctx.comment.region.finish = i - 1
      end
      ctx.comment = nil
      ctx.comment_i = nil
      ctx.headings[#ctx.headings + 1] = { role = line:match(HEAD), line = i }
    end
  elseif ctx.tool then
    -- Inside an open yap:tool region. Its closer ends it; a `# @role` line here
    -- is tool *content* (a model quoting a heading), recorded as an inner
    -- heading so view() can bound the region only when it never closes.
    if line:match(TOOL_CLOSE) then
      ctx.guard_tool = ctx.tool.start
      end_tool(ctx, i)
      ctx.region = nil
    elseif line:match(TOOL_OPEN) then
      -- A second opener while a region is open means the first was never
      -- closed (the backend never nests them): bound it at its first inner
      -- heading — or here — so one broken region cannot swallow the ones after
      -- it, and restart at this line.
      local inner = ctx.tool.inner
      local bound = (inner and inner[1] and inner[1].line - 1) or (i - 1)
      end_tool(ctx, math.max(bound, ctx.tool.start))
      if inner then
        -- These were suppressed as content while the broken region was open;
        -- they are real message boundaries after all. They are all older than
        -- any heading already recorded, and headings were not recorded while
        -- the region was open, so appending keeps the list ordered.
        for _, h in ipairs(inner) do
          ctx.headings[#ctx.headings + 1] = h
        end
      end
      open_tool(ctx, i, line)
    elseif line:match("^<!%-%- /yap:ui") then
      ctx.tool.ui_finish = i
    elseif line:match("^<!%-%- yap:ui %-%->%s*$") then
      if not ctx.tool.ui_start then
        ctx.tool.ui_start = i
      end
    elseif line:match(HEAD) then
      local inner = ctx.tool.inner
      if not inner then
        inner = {}
        ctx.tool.inner = inner
      end
      inner[#inner + 1] = { role = line:match(HEAD), line = i }
    else
      -- Plain content inside the tool region. A :YapClear placeholder marks a
      -- replaced result body; between the paired yap:ui markers this is the
      -- display diff, counted so an edit/write fold can show its size.
      if line:match("^%[output cleared") then
        ctx.tool.cleared = true
      end
      if ctx.tool.ui_start and not ctx.tool.ui_finish then
        local c = line:sub(1, 1)
        if c == "+" and line:sub(1, 3) ~= "+++" then
          ctx.tool.diff_plus = (ctx.tool.diff_plus or 0) + 1
        elseif c == "-" and line:sub(1, 3) ~= "---" then
          ctx.tool.diff_minus = (ctx.tool.diff_minus or 0) + 1
        end
      end
    end
  else
    local c, n = fence_run(line)
    if c then
      ctx.fence = { char = c, n = n }
    elseif line:match(HEAD) then
      ctx.headings[#ctx.headings + 1] = { role = line:match(HEAD), line = i }
      ctx.region = nil
    elseif line:match(TOOL_OPEN) and ctx.region ~= "tool" then
      open_tool(ctx, i, line)
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
    events_n = #ctx.events,
    guard_decisions_n = #ctx.guard_decisions,
    tool_durations_n = #ctx.tool_durations,
    tool_outcomes_n = #ctx.tool_outcomes,
    guard_tool = ctx.guard_tool,
    region = ctx.region,
    fence = ctx.fence and { char = ctx.fence.char, n = ctx.fence.n } or nil,
    comment_kind = ctx.comment and ctx.comment.kind or nil,
    comment_i = ctx.comment and ctx.comment_i or nil,
    comment_finish = ctx.comment and ctx.comment.region and ctx.comment.region.finish or nil,
    tool_i = ctx.tool_i,
    tool_finish = ctx.tool and ctx.tool.finish or nil,
    tool_header_finish = ctx.tool and ctx.tool.header_finish or nil,
    tool_ui_start = ctx.tool and ctx.tool.ui_start or nil,
    tool_ui_finish = ctx.tool and ctx.tool.ui_finish or nil,
    tool_inner_n = ctx.tool and ctx.tool.inner and #ctx.tool.inner or 0,
    tool_diff_plus = ctx.tool and ctx.tool.diff_plus or nil,
    tool_diff_minus = ctx.tool and ctx.tool.diff_minus or nil,
    tool_cleared = ctx.tool and ctx.tool.cleared or nil,
  }
end

local function restore(ctx, cp)
  for i = #ctx.headings, cp.headings_n + 1, -1 do
    ctx.headings[i] = nil
  end
  for i = #ctx.regions, cp.regions_n + 1, -1 do
    ctx.regions[i] = nil
  end
  for i = #ctx.events, cp.events_n + 1, -1 do
    ctx.events[i] = nil
  end
  for i = #ctx.guard_decisions, cp.guard_decisions_n + 1, -1 do
    ctx.guard_decisions[i] = nil
  end
  for i = #ctx.tool_durations, cp.tool_durations_n + 1, -1 do
    ctx.tool_durations[i] = nil
  end
  for i = #ctx.tool_outcomes, cp.tool_outcomes_n + 1, -1 do
    ctx.tool_outcomes[i] = nil
  end
  ctx.guard_tool = cp.guard_tool
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
    ctx.tool.header_finish = cp.tool_header_finish
    ctx.tool.ui_start = cp.tool_ui_start
    ctx.tool.ui_finish = cp.tool_ui_finish
    ctx.tool.diff_plus = cp.tool_diff_plus
    ctx.tool.diff_minus = cp.tool_diff_minus
    ctx.tool.cleared = cp.tool_cleared
    if ctx.tool.inner then
      for i = #ctx.tool.inner, cp.tool_inner_n + 1, -1 do
        ctx.tool.inner[i] = nil
      end
    end
    ctx.tool_i = cp.tool_i
  else
    ctx.tool = nil
    ctx.tool_i = nil
  end
end

-- End line of the leading YAML frontmatter (`---` … `---`), or nil.
local function frontmatter_end(lines)
  if not (lines[1] and lines[1]:match("^%-%-%-%s*$")) then
    return nil
  end
  for i = 2, #lines do
    if lines[i]:match("^%-%-%-%s*$") then
      return i
    end
  end
  return nil
end

-- Attach each event to the assistant fold that owns it. An event inside a
-- reply (a stop marker) belongs to that reply; an event in a user block (a
-- cost override) belongs to the reply that follows it. `assistant` is the
-- owning `# @assistant` heading line, or nil when none follows.
local function attach_assistant(ctx)
  local headings = ctx.headings
  local h = 1
  for _, d in ipairs(ctx.events) do
    while h <= #headings and headings[h].line <= d.line do
      h = h + 1
    end
    local owner = headings[h - 1]
    if owner and owner.role == "assistant" then
      d.assistant = owner.line
    else
      local j = h
      while j <= #headings and headings[j].role ~= "assistant" do
        j = j + 1
      end
      d.assistant = headings[j] and headings[j].line or nil
    end
  end
end

-- The parse result callers see. An unclosed tool region is malformed (a
-- killed stream, or a hand-edited buffer): bound it at its first inner heading
-- and restore that heading as a real message boundary, so it can never swallow
-- the rest of the conversation. A *closed* region keeps its inner headings as
-- content — a model quoting `# @user` inside a tool result must not split the
-- message (R-markers-not-sent: the result is ordinary transcript text).
local function view(ctx, count, frontmatter)
  -- Guard decisions and durations trail their tool's closer and belong to its
  -- fold: extend the tool's fold extent so those markers hide with the tool
  -- instead of lingering as visible prose. Recompute from scratch every call
  -- so a tail edit that adds, changes or drops one is reflected.
  for _, r in ipairs(ctx.regions) do
    if r.kind == "tool" then
      r.fold_finish = nil
    end
  end
  local function extend_tool_folds(list)
    local ri = 1
    for _, d in ipairs(list) do
      while ri <= #ctx.regions and ctx.regions[ri].start < d.tool_start do
        ri = ri + 1
      end
      local r = ctx.regions[ri]
      if r and r.start == d.tool_start then
        r.fold_finish = math.max(r.fold_finish or r.finish or 0, d.line)
      end
    end
  end
  extend_tool_folds(ctx.guard_decisions)
  extend_tool_folds(ctx.tool_durations)
  extend_tool_folds(ctx.tool_outcomes)
  attach_assistant(ctx)
  local open
  for i = #ctx.regions, 1, -1 do
    local r = ctx.regions[i]
    if r.kind == "tool" and not r.finish then
      open = r
      break
    end
  end
  local inner = open and open.inner
  if not inner or #inner == 0 then
    return {
      headings = ctx.headings,
      regions = ctx.regions,
      count = count,
      frontmatter = frontmatter,
      events = ctx.events,
      guard_decisions = ctx.guard_decisions,
      tool_durations = ctx.tool_durations,
      tool_outcomes = ctx.tool_outcomes,
    }
  end
  local cut = inner[1].line
  local regions = {}
  for i, r in ipairs(ctx.regions) do
    if r == open then
      regions[i] = {
        kind = r.kind,
        start = r.start,
        finish = math.max(cut - 1, r.start),
        header_finish = r.header_finish,
        ui_start = r.ui_start,
        ui_finish = r.ui_finish,
        inner = inner,
        unclosed = true, -- still needs its closer at end of turn (open_tail)
      }
    else
      regions[i] = r
    end
  end
  local headings = {}
  for _, h in ipairs(ctx.headings) do
    headings[#headings + 1] = h
  end
  for _, h in ipairs(inner) do
    headings[#headings + 1] = h
  end
  table.sort(headings, function(a, b)
    return a.line < b.line
  end)
  return {
    headings = headings,
    regions = regions,
    count = count,
    frontmatter = frontmatter,
    events = ctx.events,
    guard_decisions = ctx.guard_decisions,
    tool_durations = ctx.tool_durations,
    tool_outcomes = ctx.tool_outcomes,
  }
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
  local frontmatter = frontmatter_end(lines)
  local ctx = new_ctx()
  local checkpoint
  for i, line in ipairs(lines) do
    if i == #lines then
      checkpoint = snapshot(ctx)
    end
    step(ctx, i, line)
  end

  local p = view(ctx, #lines, frontmatter)
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
  local count = vim.api.nvim_buf_line_count(buf)
  if count < cached.parse.count then
    return parse(buf)
  end
  -- Only the tail is rescanned, so only the tail is read. A full read costs
  -- ~1.8ms at 64k lines and made `extend` as expensive as a full parse; the
  -- checkpoint already carries the scanner state for everything above it.
  local base = cached.parse.count - 1
  local tail = vim.api.nvim_buf_get_lines(buf, base, -1, false)
  local ctx = cached.ctx
  restore(ctx, cached.checkpoint)
  local checkpoint
  for i = cached.parse.count, count do
    if i == count then
      checkpoint = snapshot(ctx)
    end
    step(ctx, i, tail[i - base])
  end
  local p = view(ctx, count, cached.parse.frontmatter)
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
--- on its own line and is dropped through its bare `-->` closer. The Go
--- document server drops the same markers when it builds the request; this is
--- the raw-output counterpart, used by eval.lua to clean one-shot
--- `yap send` responses.
function M.strip_markers(text)
  local out = {}
  local in_marker = false
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if in_marker then
      if line:match("^%-%->%s*$") then
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

--- Decode a tool region's JSON header. The header is the single-line form
--- (`<!-- yap:tool {…} -->`) or the multi-line form (the JSON between the
--- opener and its `-->`). Returns nil when the region has no closed header or
--- the JSON is not a usable tool record.
---@param lines string[]
---@param r table a region from parse()/scan_lines()
---@return table|nil
-- decode_header(lines, r, base): lines[base+i] is buffer line i. base is 0
-- for a full line list; fold.lua passes a header slice with base = r.start-1.
local function decode_header(lines, r, base)
  base = base or 0
  if not r.header_finish then
    return nil
  end
  local function L(i)
    return lines[i - base]
  end
  local text
  if r.header_finish == r.start then
    text = (L(r.start) or ""):match("^<!%-%- yap:tool (.+) %-%->%s*$")
  else
    local acc = {}
    for i = r.start + 1, r.header_finish - 1 do
      acc[#acc + 1] = L(i)
    end
    text = table.concat(acc, "\n")
  end
  if not text then
    return nil
  end
  local ok, h = pcall(vim.json.decode, text)
  if ok and type(h) == "table" and h.name then
    return h
  end
  return nil
end

--- Structural parse of a plain line list (a session file read from disk, or a
--- `list()` slice). Same scanner as `parse(buf)`; used where no buffer exists.
---@param lines string[]
---@return table { headings, regions, count, frontmatter }
function M.scan_lines(lines)
  local ctx = new_ctx()
  for i, line in ipairs(lines) do
    step(ctx, i, line)
  end
  return view(ctx, #lines, frontmatter_end(lines))
end

--- Tool regions of a buffer with their header and body line ranges, for
--- `:YapClear`. `body_start`/`body_finish` delimit the result text only (the
--- header and the paired `yap:ui` diff are excluded); `id` is the tool-call id
--- from the header, used to point the placeholder at its audit-log lines.
---@param buf integer
---@return table[]
function M.tool_regions(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local out = {}
  for _, r in ipairs(parse(buf).regions) do
    if r.kind == "tool" then
      local finish = math.max(r.finish or #lines, r.start)
      local h = decode_header(lines, r)
      out[#out + 1] = {
        start = r.start,
        header_finish = r.header_finish,
        body_start = (r.header_finish or r.start) + 1,
        body_finish = (r.ui_start and r.ui_start - 1) or (finish - 1),
        finish = finish,
        id = h and h.id or nil,
        open = r.finish == nil or r.unclosed == true,
      }
    end
  end
  return out
end

--- Body lines of the first or last `# @role` message in a line list, heading
--- excluded and surrounding blank lines trimmed. Fence- and comment-aware, so a
--- `# @user` quoted inside a fenced result is content, not a boundary.
---@param lines string[]
---@param role string
---@param last boolean|nil
---@return string[]
function M.role_body(lines, role, last)
  local scan = M.scan_lines(lines)
  local target
  if last then
    for i = #scan.headings, 1, -1 do
      if scan.headings[i].role == role then
        target = scan.headings[i].line
        break
      end
    end
  else
    for _, h in ipairs(scan.headings) do
      if h.role == role then
        target = h.line
        break
      end
    end
  end
  if not target then
    return {}
  end
  local stop = #lines
  if not last then
    for _, h in ipairs(scan.headings) do
      if h.line > target then
        stop = h.line - 1
        break
      end
    end
  end
  local acc = {}
  for i = target + 1, stop do
    acc[#acc + 1] = lines[i]
  end
  while #acc > 0 and acc[1]:match("^%s*$") do
    table.remove(acc, 1)
  end
  while #acc > 0 and acc[#acc]:match("^%s*$") do
    table.remove(acc)
  end
  return acc
end

--- Dangling regions left by an interrupted stream, as a repair recipe:
--- `comment` when a marker or a multi-line tool header never closed (append
--- `-->`), `tool` when a tool region is still open (append its closer).
---@param buf integer
---@return {comment:boolean|nil, tool:boolean|nil}
function M.open_tail(buf)
  local p = parse(buf)
  for i = #p.regions, 1, -1 do
    local r = p.regions[i]
    if not r.finish or r.unclosed then
      if r.kind == "tool" then
        return { comment = r.header_finish == nil, tool = true }
      end
      return { comment = true }
    end
  end
  return {}
end

function M.last_answer(lines)
  local scan = M.scan_lines(lines)
  for h = #scan.headings, 1, -1 do
    local heading = scan.headings[h]
    if heading.role == "assistant" then
      local stop = scan.headings[h + 1] and scan.headings[h + 1].line - 1 or #lines
      local content = {}
      local region = 1
      local skipped_region = false
      for i = heading.line + 1, stop do
        while scan.regions[region] and (scan.regions[region].finish or #lines) < i do
          region = region + 1
        end
        local r = scan.regions[region]
        if (r and i >= r.start and i <= (r.finish or #lines)) or lines[i]:match(M.MARKER_LINE) then
          while #content > 0 and content[#content]:match("^%s*$") do
            table.remove(content)
          end
          skipped_region = true
        elseif not (skipped_region and lines[i]:match("^%s*$")) then
          content[#content + 1] = lines[i]
          skipped_region = false
        end
      end
      while #content > 0 and content[1]:match("^%s*$") do
        table.remove(content, 1)
      end
      while #content > 0 and content[#content]:match("^%s*$") do
        table.remove(content)
      end
      if #content > 0 then
        return content
      end
    end
  end
  return {}
end

M.HEAD = HEAD
M.MARKER_LINE = MARKER_LINE
M.TOOL_OPEN = TOOL_OPEN
M.TOOL_CLOSE = TOOL_CLOSE
M.COMMENT_OPEN = COMMENT_OPEN
M.decode_header = decode_header
M.fence_run = fence_run

return M
