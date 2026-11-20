-- Conversation document primitives: what a buffer would send, plus
-- appending/following streamed content. This is the buffer-is-state core.
--
-- Parsing is not here: the Go document server owns the transcript → request
-- conversion (R-single-reader), so messages() is a query rather than a Lua
-- implementation of the flatten/merge/marker rules.

local M = {}

-- ─── Buffer ↔ messages ─────────────────────────────────────────────────────

--- The messages this buffer would send, asked of the document server.
--- Returns nil when no client is attached (the backend then validates the
--- request itself). Fold, motion and text-object consumers keep using the
--- local structural scanner; only send semantics come from Go.
---@param buf integer
---@return {role:string, content:string}[]|nil
function M.messages(buf)
  return require("harness.client.lsp").messages(buf)
end

-- ─── Streaming append ──────────────────────────────────────────────────────

function M.append_text(buf, text)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local fold = require("harness.ui.fold")
  -- append_text only ever extends the last line, so the fold engine can
  -- capture just the tail fold and extend the cached structural parse instead
  -- of rescanning the whole buffer (R-stream-parse).
  fold.before_change(buf, true)
  local row = vim.api.nvim_buf_line_count(buf) - 1
  local col = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
  vim.api.nvim_buf_set_text(buf, row, col, row, col, vim.split(text, "\n", { plain = true }))
  fold.after_append(buf, true)
end

--- Windows whose cursor sits on the last line of `buf`: the user is
--- "following" the end of the conversation (pressed G, or was left there
--- by the previous chunk). Sampled BEFORE an append, because following
--- itself moves the cursor to the end.
function M.following_windows(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  local wins = {}
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, w)
    if ok and cur[1] >= count then
      wins[#wins + 1] = w
    end
  end
  return wins
end

--- Reconcile the follower set before a buffer change. Drop a follower whose
--- cursor no longer matches the exact tail position Yap last requested — that
--- difference is explicit user movement, checked synchronously to avoid
--- CursorMoved event races. Adopt any window that has since joined the tail
--- (the user pressed G after the send), so following means "cursor on the
--- tail line", not only the send-time snapshot.
function M.sync_followers(buf, wins, expected, excluded)
  for i = #wins, 1, -1 do
    local w = wins[i]
    if (excluded and excluded[w]) or not vim.api.nvim_win_is_valid(w) or vim.api.nvim_win_get_buf(w) ~= buf then
      expected[w] = nil
      table.remove(wins, i)
    else
      local want = expected[w]
      local ok, cur = pcall(vim.api.nvim_win_get_cursor, w)
      if not ok or (want and (cur[1] ~= want[1] or cur[2] ~= want[2])) then
        expected[w] = nil
        table.remove(wins, i)
      end
    end
  end
  local count = vim.api.nvim_buf_line_count(buf)
  local member = {}
  for _, w in ipairs(wins) do
    member[w] = true
  end
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if not member[w] and not (excluded and excluded[w]) then
      local ok, cur = pcall(vim.api.nvim_win_get_cursor, w)
      if ok and cur[1] >= count then
        wins[#wins + 1] = w
      end
    end
  end
end

--- Keep follower windows on the real stream end at column zero. Windows that
--- did not start at the tail, or were removed by sync_followers, are never
--- moved.
function M.follow_windows(buf, wins, expected)
  if #wins == 0 or vim.api.nvim_get_mode().mode ~= "n" then
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)
  for i = #wins, 1, -1 do
    local w = wins[i]
    if not vim.api.nvim_win_is_valid(w) or vim.api.nvim_win_get_buf(w) ~= buf then
      expected[w] = nil
      table.remove(wins, i)
    else
      expected[w] = { count, 0 }
      local ok = pcall(vim.api.nvim_win_set_cursor, w, expected[w])
      if not ok then
        expected[w] = nil
        table.remove(wins, i)
      end
    end
  end
end

--- Append whole lines as a standalone chunk, separated from the buffer's current
--- end by exactly one blank line (R-blank-lines), no matter how the buffer ends.
--- All structural appends (headings, error markers) go through here.
function M.append_lines(buf, chunk)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local n = vim.api.nvim_buf_line_count(buf)
  local keep = n
  while keep > 1 and vim.api.nvim_buf_get_lines(buf, keep - 1, keep, false)[1] == "" do
    keep = keep - 1
  end
  local lines = vim.deepcopy(chunk)
  table.insert(lines, 1, "")
  local fold = require("harness.ui.fold")
  fold.before_change(buf)
  vim.api.nvim_buf_set_lines(buf, keep, n, false, lines)
  fold.after_append(buf)
end

--- The role of the buffer's last message heading (`# @user`, ...), or nil
--- when the buffer has no heading yet. This is the single place that reads
--- "what message would an append land in", shared by the plain-text inserter
--- (append_message) and the snippet inserter so both reuse the trailing
--- heading instead of duplicating it.
function M.trailing_role(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local headings = require("harness.model.structure").parse(buf).headings
  return headings[#headings] and headings[#headings].role or nil
end

--- Guarantee a trailing `# @user` prompt is followed by a blank line, so the
--- user can start typing with `i`/`p` instead of `o`. A session saved by an
--- older build (or a hand edit) can end on the heading itself; repairing it
--- here keeps every adopted and completed session writable.
function M.ensure_prompt_blank(buf)
  if not vim.api.nvim_buf_is_valid(buf) or M.trailing_role(buf) ~= "user" then
    return
  end
  local n = vim.api.nvim_buf_line_count(buf)
  local last = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1]
  if last ~= "" then
    vim.api.nvim_buf_set_lines(buf, n, n, false, { "" })
  end
end

--- Append `lines` as a `# @<role>` message. If the buffer's last heading
--- is already that role (e.g. the empty `# @user` prompt a completed turn
--- leaves behind), the lines fill that message — merging with any body the
--- user already typed — instead of emitting a duplicate heading above it.
--- Otherwise a fresh heading message is appended. This is the single place
--- that decides reuse-vs-wrap for plain-text appends; snippet appends use
--- trailing_role directly for the same decision. (R-role-alternation makes reuse and a new
--- adjacent message parse the same, so this is purely about keeping the
--- visible buffer well-formed.)
function M.append_message(buf, role, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local headings = require("harness.model.structure").parse(buf).headings
  local heading = headings[#headings] and headings[#headings].line or nil
  if not (heading and headings[#headings].role == role) then
    local message = { "# @" .. role, "" }
    vim.list_extend(message, lines)
    M.append_lines(buf, message)
    return
  end
  -- Keep everything through the heading, then any body already under it,
  -- then the new lines (R-blank-lines: one blank line after the heading, one between
  -- merged bodies).
  local out = {}
  for i = 1, heading do
    out[#out + 1] = all[i]
  end
  local existing = {}
  for i = heading + 1, #all do
    existing[#existing + 1] = all[i]
  end
  while #existing > 0 and existing[#existing]:match("^%s*$") do
    existing[#existing] = nil
  end
  while #existing > 0 and existing[1]:match("^%s*$") do
    table.remove(existing, 1)
  end
  out[#out + 1] = ""
  for _, l in ipairs(existing) do
    out[#out + 1] = l
  end
  if #existing > 0 then
    out[#out + 1] = ""
  end
  for _, l in ipairs(lines) do
    out[#out + 1] = l
  end
  -- Replace only the differing span. Rewriting unchanged history would
  -- invalidate its fold anchors (and any other plugin's extmarks).
  local first, last, tail = 0, #all, #out
  while first < last and first < tail and all[first + 1] == out[first + 1] do
    first = first + 1
  end
  while last > first and tail > first and all[last] == out[tail] do
    last, tail = last - 1, tail - 1
  end
  local fold = require("harness.ui.fold")
  fold.before_change(buf)
  vim.api.nvim_buf_set_lines(buf, first, last, false, vim.list_slice(out, first + 1, tail))
  fold.after_append(buf)
end

-- Hold an incomplete structural line until it can be classified. A pipe can
-- split even the first bytes of a marker; painting those as prose and folding
-- them a frame later causes a flash. Non-structural prose still streams.
-- The caller owns the returned remainder and flushes it verbatim at EOF.
function M.split_stream_tail(buf, text)
  local newline = text:match(".*()\n") or 0
  local tail = text:sub(newline + 1)
  if newline == 0 then
    tail = (vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] or "") .. tail
  end
  if tail == "" then
    return text, ""
  end
  for _, prefix in ipairs({ "# @", "<!-- yap:", "<!-- /yap:" }) do
    if prefix:sub(1, #tail) == tail or tail:sub(1, #prefix) == prefix then
      -- A complete single-line comment is already safely classifiable.
      if tail:sub(-3) ~= "-->" then
        return text:sub(1, newline), text:sub(newline + 1)
      end
    end
  end
  return text, ""
end

return M
