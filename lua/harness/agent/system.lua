-- The harness's own system message: the "About Yap" boilerplate injected as
-- the first system message on every send, plus the user's agents_file rules
-- (or the configured fallback system prompt) for new sessions.

local M = {}

local template = require("harness.agent.template")
local paths = require("harness.path")

-- The plugin's install root, derived from this file's location on the
-- runtimepath, so the self-help hint points at the real README/doc wherever
-- yap is installed instead of a hardcoded development path.
local yap_install_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

local function harness()
  return require("harness")
end

--- The "About Yap" boilerplate, independent of agents_file (the user's rules)
--- and never stored in the session file. `buf` is used only for the per-send
--- session-path hint (the agent's scratch/assets location).
function M.about(buf)
  local skills = template.skills_intro_lines()
  local agents = template.agents_intro_lines()
  local about = [[# About Yap

You are running inside Yap, an agent harness for Neovim. The conversation is an editable Markdown buffer and the source of truth: `# @system`, `# @user`, and `# @assistant` headings delimit messages; editing or deleting a message branches or rewrites history, and the visible transcript is what is re-sent. Never emit one of those headings or a `<!-- yap:` marker line in a reply; indent or fence it instead.

Between turns, tool calls and their results are plain text in the transcript, not re-executed or re-sent. When asked about Yap itself, read `README.md` / `doc/yap.txt` in the plugin (]] .. yap_install_root .. [[) rather than guessing.

For GitHub searches and reading GitHub code, repositories, issues, pull requests, files, or Projects, use the `github` tool rather than curl, fetch, websearch, bash, or `gh`. Use other tools only if the `github` tool cannot perform the needed operation; never pass the GitHub token in tool arguments.

## Skills

Skills are reusable on-demand instructions in Markdown files under ]] .. harness().config.skills_dir .. [[ (`<name>.md`). Before working in a listed domain, `read` the matching skill file and follow it; read only what you need.]]
  if skills then
    about = about .. "\n\n" .. table.concat(skills, "\n")
  end
  about = about .. "\n\n" .. [[## Parallelism and background work

When you need several independent read-only results (read, search, glob, fetch, websearch, models, ls), request them all in one message — they run concurrently. Batch your reads: opening two files at once is faster than opening them one after another.

For independent slow work, `start_task` launches bash, fetch, or websearch in the background and returns a task ID. Launch the slow call, do other useful work, then call `wait_tasks` once to collect the result before relying on it. For example, start a long test run or build, then read files or research meanwhile. Tasks end within this turn; do not start commands that conflict with ongoing work.

## Subagents

Use `subagent` to delegate a self-contained subtask that is large or independent enough to benefit from an isolated context or a different model. It blocks until the child finishes and returns the child's answer and session path; inspect the child session for its full conversation. The `agent` argument names an agent from the `## Agents` list (definition files in `agents_dir`, default `~/.config/yap/agents/<agent>.md`). To ask a follow-up, pass `session` with that path and `task` with the question (omit `agent`); this appends a user turn to the same child, preserving its system prompt and history. Pass `model` as a `provider/model` combo to run the child on the model you judge appropriate — it overrides the agent definition's `model`. Discover combos with the `models` tool: with no filter it lists the configured providers and their model counts, and with a filter it lists matching `provider/model` combos plus their price per 1M tokens when known. Without `model` the child uses the definition's `model` (a bare model name there inherits the parent's provider) and otherwise your own combo. `model` is ignored on follow-ups.]]
  if agents then
    about = about .. "\n## Agents\n\nThe `agent` argument accepts one of:\n\n" .. table.concat(agents, "\n")
  end
  -- The agent needs the session's scratch location to write throwaway
  -- scripts and generated artifacts into the session instead of /tmp or the
  -- project. This prefix is the only per-send, per-buffer message, so the
  -- path is injected here rather than stored in the session file.
  local spath = buf and paths.session_path(buf)
  if spath then
    local sdir = vim.fn.fnamemodify(spath, ":h")
    about = about
      .. "\n\n## Session files\n\nThis session lives in `"
      .. sdir
      .. "`. Write throwaway Python scripts, generated artifacts (HTML, data dumps), fetched downloads, and quick-inspection clones into its `assets/` subfolder (`"
      .. sdir
      .. "/assets/`) — the same folder that holds images the conversation references — so they stay with the session, out of the project and /tmp, and you can find files you saved there earlier in the session."
  end
  return about
end

--- The system prompt for NEW sessions: the agents_file rules when present,
--- else the configured fallback.
function M.prompt()
  local f = io.open(harness().config.agents_file, "r")
  if f then
    local text = f:read("*a")
    f:close()
    text = text:gsub("%s+$", "")
    if text ~= "" then
      return text
    end
  end
  return harness().config.system
end

return M
