-- Shared structural parser for folding and navigation.
-- Extracted from harness.fold

local M = {}

local HEAD = "^# @(%a+)%s*$"
local TOOL_OPEN = "^<!%-%- yap:tool"
local TOOL_CLOSE = "^<!%-%- /yap:tool"
local COMMENT_OPEN = "^<!%-%-.*yap:%a+%s*$"

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
  return c, n, rest:sub(n + 1)
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
local model_cache = {} -- buf -> { tick, parse }

local function parse(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local cached = model_cache[buf]
  if cached and cached.tick == tick then
    return cached.parse
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local headings, regions = {}, {}
  local region, fence, comment = nil, nil, nil
  local tool
  local function end_tool(finish)
    if tool and not tool.finish then
      tool.finish = finish
    end
    tool = nil
  end

  for i, line in ipairs(lines) do
    if fence then
      local c, n, tail = fence_run(line)
      if c == fence.char and n >= fence.n and tail:match("^%s*$") then
        fence = nil
      end
    elseif comment then
      -- Inside a multi-line HTML comment: raw text until a bare `-->`
      -- (a ``` inside a comment is NOT a fence).
      if line:match("^%-%->%s*$") then
        if comment.region then
          comment.region.finish = i
        end
        comment = nil
      end
    else
      local c, n = fence_run(line)
      if c then
        fence = { char = c, n = n }
      elseif line:match(HEAD) then
        -- A heading ends an unfinished tool region; document.lua still
        -- treats headings inside well-formed tool results as result text.
        end_tool(i - 1)
        headings[#headings + 1] = { role = line:match(HEAD), line = i }
        region = nil
      elseif line:match(TOOL_OPEN) and region ~= "tool" then
        end_tool(i - 1)
        local d = { kind = "tool", start = i }
        regions[#regions + 1] = d
        tool, region = d, "tool"
        -- Pretty JSON headers are comments too: fence/heading-looking
        -- argument lines must not change the surrounding region structure.
        if not line:find("-->", 1, true) then
          comment = { kind = "tool_inner" }
        end
      elseif line:match(COMMENT_OPEN) and not line:match("%-%->") then
        if region == "tool" then
          -- A legacy yap:ui subsection inside a tool region is content of
          -- the region fold, not a fold of its own.
          comment = { kind = "tool_inner" }
        else
          local kind = line:match("yap:(%a+)") or "comment"
          local d = { kind = kind, start = i }
          regions[#regions + 1] = d
          comment = { kind = kind, region = d }
        end
      elseif line:match(TOOL_CLOSE) then
        end_tool(i)
        region = nil
      end
      -- else: plain content line
    end
  end

  local p = { headings = headings, regions = regions, count = #lines }
  model_cache[buf] = { tick = tick, parse = p }
  return p
end

function M.parse(buf)
  return parse(buf)
end

function M.clear(buf)
  model_cache[buf] = nil
end

M.HEAD = HEAD
M.TOOL_OPEN = TOOL_OPEN
M.TOOL_CLOSE = TOOL_CLOSE
M.COMMENT_OPEN = COMMENT_OPEN
M.fence_run = fence_run

return M
