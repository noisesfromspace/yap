-- yap + touchup performance profiler.
--
-- Measures the per-redraw (j/k over folds) cost and every component that
-- runs synchronously during a cursor move / screen redraw, so we can see
-- which subsystem is responsible for the "hangs then jumps" behavior on
-- large sessions.
--
-- It builds a realistic yap session buffer, applies yap's fold engine and
-- touchup's decoration provider, and times:
--
--   A. fold engine      — levels build (cold = per-edit rebuild), foldexpr
--                         per line, foldtext per fold, vim's fold eval.
--   B. touchup          — tree-sitter parse (warm/incremental), per-renderer
--                         on_win breakdown, comment-block span scan.
--   C. end-to-end       — a real `:redraw` with folds / touchup / winbar
--                         toggled in isolation.
--   D. cursor-move      — an actual j-step across closed folds, with each
--                         subsystem toggled to find the dominant cost.
--   E. scaling          — the top metrics at several buffer sizes.
--
-- Requires the markdown + markdown_inline tree-sitter parsers on the rtp.
--
-- Run headless (faithful compute timings):
--   PARSERS=/nix/store/d62hq0xl9nf3vsvx52z2h4fs0z7mzp2d-nvim-treesitter-grammars
--   nvim --headless -u NONE -i NONE \
--     --cmd "set rtp^=$PWD,/opt/code/touchup.nvim,$PARSERS" \
--     -l tests/perf.lua
--
-- Run interactively (adds real UI paint to the redraw numbers):
--   nvim -u NONE -i NONE \
--     --cmd "set rtp^=$PWD,/opt/code/touchup.nvim,$PARSERS" \
--     -l tests/perf.lua
--
-- Tunables:
--   PERF_SIZE      lines in the synthetic session (default 14000)
--   PERF_WIN_H     window height in lines (default 40)
--   PERF_SIZES     sizes for the scaling table (default 4000,14000,40000)

local api = vim.api
local uv = vim.uv or vim.loop

local SIZE = tonumber(vim.env.PERF_SIZE) or 14000
local WIN_H = tonumber(vim.env.PERF_WIN_H) or 40
local WIN_W = tonumber(vim.env.PERF_WIN_W) or 120
local SIZES = vim.env.PERF_SIZES and vim.split(vim.env.PERF_SIZES, ",") or { 4000, 14000, 40000 }
for i, s in ipairs(SIZES) do
  SIZES[i] = tonumber(s)
end

-- ── helpers ────────────────────────────────────────────────────────────────

local results = {} -- { label, ms, note }

local function now()
  return uv.hrtime()
end

local function elapsed(t0)
  return (uv.hrtime() - t0) / 1e6
end

-- Time fn over `iters` runs after one warmup; returns average ms.
local function timeit(fn, iters)
  iters = iters or 50
  fn() -- warmup
  local t0 = now()
  for _ = 1, iters do
    fn()
  end
  return elapsed(t0) / iters
end

local function add(label, fn, iters, note)
  local ok, ms_or_err = pcall(function()
    return timeit(fn, iters)
  end)
  if ok then
    results[#results + 1] = { label = label, ms = ms_or_err, note = note }
  else
    results[#results + 1] = { label = label, ms = -1, note = "ERROR: " .. tostring(ms_or_err) }
  end
end

local function hdr(s)
  print("\n━━━ " .. s .. " " .. string.rep("━", math.max(2, 58 - #s)))
end

-- ── build a realistic session buffer ───────────────────────────────────────

local function build_session(nlines)
  local lines = { "---", "description: perf synthetic session", "provider: test", "model: test-model", "---", "" }
  lines[#lines + 1] = "# @system"
  lines[#lines + 1] = "You are a coding agent. Be concise."

  local tool_id = 0
  local function tool(result_lines)
    tool_id = tool_id + 1
    lines[#lines + 1] = '<!-- yap:tool {"id":"call_' .. tool_id .. '","name":"bash","arguments":{"command":"make"}} -->'
    lines[#lines + 1] = "Successfully ran command."
    for i = 1, result_lines do
      lines[#lines + 1] = "output line " .. i
    end
    lines[#lines + 1] = "```"
    for i = 1, result_lines do
      lines[#lines + 1] = "fenced result " .. i
    end
    lines[#lines + 1] = "```"
    lines[#lines + 1] = "<!-- /yap:tool -->"
  end

  local function thinking()
    lines[#lines + 1] = "<!-- yap:thinking"
    lines[#lines + 1] = "Reasoning about the task in a few lines of prose."
    lines[#lines + 1] = "-->"
  end

  while #lines < nlines do
    lines[#lines + 1] = "# @user"
    lines[#lines + 1] = "Please fix the bug in the parser, here is some **context** and a `code` span."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "# @assistant"
    lines[#lines + 1] = "Here is the analysis, with a list:"
    lines[#lines + 1] = "- first item"
    lines[#lines + 1] = "- second item"
    thinking()
    tool(6)
    lines[#lines + 1] = "# @assistant"
    lines[#lines + 1] = "Follow-up reasoning."
    thinking()
    tool(10)
  end

  -- one big tool output at the end (a 2000-line bash result) to exercise a
  -- very large fold, as real sessions have.
  lines[#lines + 1] = "# @assistant"
  lines[#lines + 1] = "Dumping the large log:"
  lines[#lines + 1] = '<!-- yap:tool {"id":"big","name":"bash","arguments":{"command":"cat log"}} -->'
  for i = 1, 2000 do
    lines[#lines + 1] = "log line " .. i
  end
  lines[#lines + 1] = "<!-- /yap:tool -->"

  return lines
end

-- ── fold-setup helpers ─────────────────────────────────────────────────────

local function apply_folds(buf)
  vim.wo.foldmethod = "manual"
  vim.wo.foldtext = "v:lua.require'harness.ui.fold'.text()"
  vim.wo.foldlevel = 0
  require("harness.ui.fold").set_view_level(1) -- assistant output folded
end

local function clear_folds()
  vim.wo.foldmethod = "manual"
  vim.wo.foldexpr = "0"
  vim.wo.foldtext = "foldtext()"
end

-- ── touchup on_win simulation (mirrors init.lua) ───────────────────────────
-- extmark insertion is stubbed out so the pure computation (tree-sitter
-- queries + span scan) can be timed outside a live decoration provider.

local function make_onwin_sim(buf, win)
  local config = require("touchup.config").merge({})
  local bullets = require("touchup.bullets")
  local codeblocks = require("touchup.codeblocks")
  local commentblocks = require("touchup.commentblocks")
  local yapmod = require("touchup.yap")
  local checkboxes = require("touchup.checkboxes")
  local quotes = require("touchup.quotes")
  local admonitions = require("touchup.admonitions")
  local links = require("touchup.links")
  local markers = require("touchup.markers")
  local ns = api.nvim_create_namespace("perf-sim")

  local parser
  local ok, p = pcall(vim.treesitter.get_parser, buf, "markdown")
  if ok then
    parser = p
  end

  local real_set = api.nvim_buf_set_extmark
  local function stub_extmarks(fn)
    api.nvim_buf_set_extmark = function()
      return 0
    end
    local ok2, err = pcall(fn)
    api.nvim_buf_set_extmark = real_set
    if not ok2 then
      error(err)
    end
  end

  local function visible_trees(inline, last)
    local v = {}
    for _, tree in ipairs(inline or {}) do
      local srow, _, erow = tree:root():range()
      if erow >= 0 and srow < last then
        v[#v + 1] = tree
      end
    end
    return v
  end

  -- Each renderer as a named function for the per-renderer breakdown.
  local function build_renderers()
    local trees = parser:parse()
    local root = trees and trees[1] and trees[1]:root()
    local inline = parser:children().markdown_inline
    local itrees = inline and inline:parse()
    local top, last = 0, WIN_H
    local vis = visible_trees(itrees, last)
    return {
      {
        "parser:parse()",
        function()
          parser:parse()
        end,
      },
      {
        "bullets",
        function()
          stub_extmarks(function()
            bullets.render(ns, buf, config.bullets.icons, top, last, root)
          end)
        end,
      },
      {
        "codeblocks",
        function()
          stub_extmarks(function()
            codeblocks.render(ns, buf, top, last, root)
          end)
        end,
      },
      {
        "commentblocks (bg+status)",
        function()
          stub_extmarks(function()
            commentblocks.render(ns, buf, top, last, config.comment_blocks.enabled, config.yap.enabled)
          end)
        end,
      },
      {
        "yap headings",
        function()
          stub_extmarks(function()
            yapmod.render(ns, buf, top, last, root)
          end)
        end,
      },
      {
        "checkboxes",
        function()
          stub_extmarks(function()
            checkboxes.render(ns, buf, config.checkboxes.icons, top, last, root)
          end)
        end,
      },
      {
        "quotes",
        function()
          stub_extmarks(function()
            quotes.render(ns, buf, top, last, root)
          end)
        end,
      },
      {
        "admonitions",
        function()
          stub_extmarks(function()
            admonitions.render(ns, buf, top, last, root)
          end)
        end,
      },
      {
        "markdown_inline:parse()",
        function()
          if inline then
            inline:parse()
          end
        end,
      },
      {
        "links",
        function()
          stub_extmarks(function()
            links.render(ns, buf, top, last, vis, root)
          end)
        end,
      },
      {
        "markers",
        function()
          stub_extmarks(function()
            markers.render(ns, buf, top, last, vis, root)
          end)
        end,
      },
    }
  end

  return {
    parser = parser,
    parse = function()
      return parser and parser:parse()
    end,
    inline = function()
      local inline = parser and parser:children().markdown_inline
      return inline and inline:parse()
    end,
    renderers = build_renderers,
    run = function(topline, botline)
      stub_extmarks(function()
        local last = botline + 1
        local trees = parser:parse()
        local root = trees and trees[1] and trees[1]:root()
        if not root then
          return
        end
        if config.bullets.enabled then
          bullets.render(ns, buf, config.bullets.icons, topline, last, root)
        end
        if config.code_blocks.enabled then
          codeblocks.render(ns, buf, topline, last, root)
        end
        if config.comment_blocks.enabled or config.yap.enabled then
          commentblocks.render(ns, buf, topline, last, config.comment_blocks.enabled, config.yap.enabled)
        end
        if config.yap.enabled then
          yapmod.render(ns, buf, topline, last, root)
        end
        if config.checkboxes.enabled then
          checkboxes.render(ns, buf, config.checkboxes.icons, topline, last, root)
        end
        if config.quotes.enabled then
          quotes.render(ns, buf, topline, last, root)
        end
        if config.admonitions.enabled then
          admonitions.render(ns, buf, topline, last, root)
        end
        if vim.wo[win].conceallevel == 0 and (config.links.enabled or config.markers.enabled) then
          local inline = parser:children().markdown_inline
          local itrees = inline and inline:parse()
          local visible = {}
          for _, tree in ipairs(itrees or {}) do
            local srow, _, erow = tree:root():range()
            if erow >= topline and srow < last then
              visible[#visible + 1] = tree
            end
          end
          if config.links.enabled then
            links.render(ns, buf, topline, last, visible, root)
          end
          if config.markers.enabled then
            markers.render(ns, buf, topline, last, visible, root)
          end
        end
      end)
    end,
  }
end

-- ── end-to-end redraw timing ───────────────────────────────────────────────

local function open_window(buf)
  return api.nvim_open_win(buf, true, {
    relative = "editor",
    width = WIN_W,
    height = WIN_H,
    row = 0,
    col = 0,
    style = "minimal",
  })
end

local function scroll_to(topline)
  vim.fn.winrestview({ topline = topline, leftcol = 0 })
  vim.cmd("redraw")
end

-- ── main ───────────────────────────────────────────────────────────────────

print(string.format("=== yap+touchup perf profiler  (buffer=%d lines, window=%dx%d) ===", SIZE, WIN_W, WIN_H))

local fold = require("harness.ui.fold")
local cb = require("touchup.commentblocks")
require("touchup").setup()

local lines = build_session(SIZE)
print(string.format("built session: %d lines", #lines))

local buf = api.nvim_create_buf(false, true)
vim.bo[buf].filetype = "markdown"
api.nvim_buf_set_lines(buf, 0, -1, false, lines)
api.nvim_set_current_buf(buf)

-- force the initial (cold) tree-sitter parse once so later "warm" numbers
-- measure steady-state cost, not the one-time first parse.
local parser = vim.treesitter.get_parser(buf, "markdown")
local t0 = now()
parser:parse()
print(string.format("initial cold markdown parse: %.1f ms", elapsed(t0)))
local inline = parser:children().markdown_inline
if inline then
  t0 = now()
  inline:parse()
  print(string.format("initial cold markdown_inline parse: %.1f ms", elapsed(t0)))
end

hdr("A. fold engine (per-edit cost)")
apply_folds(buf)

-- Cold build == the O(n) block-model parse that fires after EVERY buffer
-- edit (stream flush, keystroke, etc.): changedtick bumps, cache misses.
add("fold.parse() rebuild (cold, per edit)", function()
  api.nvim_buf_set_lines(buf, -1, -1, false, { "x" })
  fold.parse(buf)
  api.nvim_buf_set_lines(buf, -2, -1, false, {})
end, 10, "this runs on every stream flush")

add("fold.parse() cached (warm)", function()
  fold.parse(buf)
end, 100)

-- foldtext for each fold type, from the parsed block model
local p = fold.parse(buf)
local starts = { msg = nil, tool = nil, think = nil, big = nil }
for _, h in ipairs(p.headings) do
  if h.role == "assistant" and not starts.msg then
    starts.msg = h.line
  end
end
for _, d in ipairs(p.regions) do
  if d.kind == "tool" and not starts.tool then
    starts.tool = d.start
  end
  if d.kind == "thinking" and not starts.think then
    starts.think = d.start
  end
  if vim.fn.getline(d.start):match('"id":"big"') and not starts.big then
    starts.big = d.start
  end
end

local function fold_end(lnum)
  for _, d in ipairs(p.regions) do
    if d.start == lnum then
      return d.finish or p.count
    end
  end
  for i, h in ipairs(p.headings) do
    if h.line == lnum then
      local nxt = p.headings[i + 1]
      return nxt and (nxt.line - 1) or p.count
    end
  end
  return vim.api.nvim_buf_line_count(buf)
end

for name, lnum in pairs(starts) do
  if lnum then
    local fend = fold_end(lnum)
    if fend > lnum then
      local n = name == "big" and 50 or 200
      add(string.format("fold.text() %s fold (%d lines)", name, fend - lnum + 1), function()
        fold.text(lnum, fend)
      end, n)
    end
  end
end

hdr("B. touchup components (folds off so edits are clean)")
clear_folds(buf)

local sim = make_onwin_sim(buf, 0)
if sim.parser then
  add("parser:parse() warm", function()
    sim.parse()
  end, 200)
  add("parser:parse() after 1-line append", function()
    api.nvim_buf_set_lines(buf, -1, -1, false, { "x" })
    sim.parse()
    api.nvim_buf_set_lines(buf, -2, -1, false, {})
  end, 10, "tree-sitter incremental re-parse per stream flush")
  if inline then
    add("markdown_inline:parse() warm", function()
      sim.inline()
    end, 100)
    add("markdown_inline:parse() after 1-line append", function()
      api.nvim_buf_set_lines(buf, -1, -1, false, { "x" })
      sim.inline()
      api.nvim_buf_set_lines(buf, -2, -1, false, {})
    end, 10)
  end

  -- per-renderer breakdown of a single on_win pass over the viewport
  print("\n  per-renderer on_win breakdown (40-line viewport, extmarks stubbed):")
  local rlist = sim.renderers()
  local total = 0
  for _, r in ipairs(rlist) do
    local name, fn = r[1], r[2]
    local ms = timeit(fn, 200)
    total = total + ms
    print(string.format("    %-28s %7.3f ms", name, ms))
    results[#results + 1] = { label = "  on_win: " .. name, ms = ms }
  end
  print(string.format("    %-28s %7.3f ms", "(sum, stubbed extmarks)", total))

  add("touchup full on_win (40-line viewport)", function()
    sim.run(0, WIN_H)
  end, 50, "stubbed extmarks; parse is warm here")
else
  print("  (markdown parser unavailable — tree-sitter numbers skipped)")
end

-- comment-block span scan: cold full scan vs warm vs incremental append
local all = api.nvim_buf_get_lines(buf, 0, -1, false)
add("commentblocks.spans() full scan (cold)", function()
  cb.spans(all)
end, 10)

cb.reset(buf)
cb._spans(buf)
add("commentblocks._spans() after 1-line append", function()
  api.nvim_buf_set_lines(buf, -1, -1, false, { "x" })
  cb._spans(buf)
end, 200, "incremental (folds off); buffer grows by 200 lines")

hdr("C. end-to-end redraw (headless under-measures paint)")
local win = open_window(buf)

local function time_redraw(iters)
  return timeit(function()
    vim.cmd("redraw")
  end, iters)
end

scroll_to(math.max(1, #lines - 3000))

local baseline = time_redraw(100)
results[#results + 1] = { label = "redraw: baseline (no folds/touchup/winbar)", ms = baseline }
print(string.format("  baseline redraw: %.3f ms", baseline))

clear_folds()
vim.wo.winbar = ""
local touchup_only = time_redraw(100)
results[#results + 1] = { label = "redraw: + touchup (folds off)", ms = touchup_only }
print(string.format("  touchup-only redraw: %.3f ms", touchup_only))

require("touchup").disable()
apply_folds(buf)
local folds_only = time_redraw(100)
results[#results + 1] = { label = "redraw: + folds (touchup off)", ms = folds_only }
print(string.format("  folds-only redraw: %.3f ms", folds_only))

require("touchup").setup()
vim.wo.winbar = "%!v:lua.require'harness'.winbar()"
vim.b[buf].yap_provider = "test"
vim.b[buf].yap_model = "test-model"
vim.b[buf].yap_usage = { prompt = 120000, completion = 3000, cost = 0.0042 }
vim.b[buf].yap_session_usage = { cost = 0.51 }
local everything = time_redraw(100)
results[#results + 1] = { label = "redraw: folds + touchup + winbar (full)", ms = everything }
print(string.format("  full redraw: %.3f ms", everything))

hdr("D. cursor move over folds (the j/k latency)")
apply_folds(buf)
fold.set_view_level(1) -- view 1: assistant output folded, user prompts open
scroll_to(1)
api.nvim_win_set_cursor(0, { 1, 0 })

local function j_step(with_redraw)
  return function()
    api.nvim_win_set_cursor(0, { api.nvim_win_get_cursor(0)[1] + 1, 0 })
    if with_redraw then
      vim.cmd("redraw")
    end
  end
end

local function report_j(label, fn)
  local ms = timeit(fn, 40)
  results[#results + 1] = { label = label, ms = ms }
  print(string.format("  %-42s %.3f ms", label, ms))
end

report_j("j-step: set_cursor only", j_step(false))
report_j("j-step: set_cursor + redraw (full)", j_step(true))

local saved_wb = vim.wo.winbar
vim.wo.winbar = ""
report_j("j-step: winbar OFF", j_step(true))
vim.wo.winbar = saved_wb

require("touchup").disable()
report_j("j-step: touchup OFF", j_step(true))
require("touchup").setup()

clear_folds()
report_j("j-step: folds OFF (touchup still on)", j_step(true))
apply_folds(buf)
fold.set_view_level(1)

hdr("E. scaling (key metrics by buffer size)")
print(
  string.format(
    "  %-8s %-16s %-16s %-16s %-16s",
    "size",
    "levels rebuild",
    "cold parse",
    "parse+append",
    "j-step+redraw"
  )
)
for _, size in ipairs(SIZES) do
  local ls = build_session(size)
  local b2 = api.nvim_create_buf(false, true)
  vim.bo[b2].filetype = "markdown"
  api.nvim_buf_set_lines(b2, 0, -1, false, ls)
  api.nvim_set_current_buf(b2)

  local p2 = vim.treesitter.get_parser(b2, "markdown")
  local t1 = now()
  p2:parse()
  local parse_ms = elapsed(t1)

  -- parse after append, with folds OFF (isolated from fold rebuild)
  clear_folds()
  local append_ms = timeit(function()
    api.nvim_buf_set_lines(b2, -1, -1, false, { "x" })
    p2:parse()
    api.nvim_buf_set_lines(b2, -2, -1, false, {})
  end, 5)

  -- fold levels rebuild (per-edit)
  apply_folds(b2)
  local t2 = now()
  fold.parse(b2)
  local build_ms = elapsed(t2)

  -- j-step with folds + touchup on (the real cursor-move cost)
  local w2 = api.nvim_open_win(b2, true, {
    relative = "editor",
    width = WIN_W,
    height = WIN_H,
    row = 0,
    col = 0,
    style = "minimal",
  })
  scroll_to(1)
  api.nvim_win_set_cursor(0, { 1, 0 })
  local jms = timeit(function()
    api.nvim_win_set_cursor(0, { api.nvim_win_get_cursor(0)[1] + 1, 0 })
    vim.cmd("redraw")
  end, 20)
  api.nvim_win_close(w2, true)
  api.nvim_buf_delete(b2, { force = true })

  print(string.format("  %-8d %-16.1f %-16.1f %-16.1f %-16.3f", size, build_ms, parse_ms, append_ms, jms))
end

hdr("summary (sorted by cost)")
table.sort(results, function(a, b)
  return a.ms > b.ms
end)
for _, r in ipairs(results) do
  if r.ms >= 0 then
    print(string.format("  %8.3f ms  %-52s %s", r.ms, r.label, r.note or ""))
  else
    print(string.format("  %8s  %-52s %s", "ERR", r.label, r.note or ""))
  end
end

print("\nDone.")
