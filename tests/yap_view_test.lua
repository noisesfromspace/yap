-- The shell-command line breaker shared by the guard board and audit view:
-- break at top-level && / || / | / ; and at existing newlines, but never
-- inside quotes, backticks, $()/${}, or a heredoc body.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local view = require("harness.view")

local function eq(got, want, msg)
  if #got ~= #want then
    error(("%s: %d lines, want %d: %s"):format(msg, #got, #want, vim.inspect(got)))
  end
  for i = 1, #want do
    assert(got[i] == want[i], ("%s: line %d = %q, want %q"):format(msg, i, got[i], want[i]))
  end
end

-- Operator breaking (leading operator on indented continuation lines).
eq(view.shell_lines("cd /opt/code/yap && echo hi", "  "), {
  "cd /opt/code/yap",
  "  && echo hi",
}, "&& break")

eq(view.shell_lines("a | b ; c || d", "  "), {
  "a",
  "  | b",
  "  ; c",
  "  || d",
}, "pipe / semi / or")

-- Heredoc: body is preserved verbatim, one line each.
eq(view.shell_lines("cd /x && python3 - <<'EOF'\nprint(1)\nprint(2)\nEOF", "  "), {
  "cd /x",
  "  && python3 - <<'EOF'",
  "print(1)",
  "print(2)",
  "EOF",
}, "quoted heredoc + &&")

-- Unquoted heredoc.
eq(view.shell_lines("cat <<END\nhello\nEND\n&& echo done", "  "), {
  "cat <<END",
  "hello",
  "END",
  "  && echo done",
}, "unquoted heredoc")

-- No break inside quotes, backticks, or command/parameter substitution.
eq(view.shell_lines('echo "a && b"', "  "), { 'echo "a && b"' }, "double quote protects &&")
eq(view.shell_lines("echo 'x | y'", "  "), { "echo 'x | y'" }, "single quote protects |")
eq(view.shell_lines("echo `echo a; b`", "  "), { "echo `echo a; b`" }, "backtick protects ;")
eq(view.shell_lines("echo $(echo a && echo b)", "  "), { "echo $(echo a && echo b)" }, "$() protects &&")
eq(view.shell_lines("x=${a:-b;c}", "  "), { "x=${a:-b;c}" }, "${} protects ;")

-- A lone `&` (redirection 2>&1) must not break.
eq(view.shell_lines("cmd 2>&1 && other", "  "), { "cmd 2>&1", "  && other" }, "redirect & intact")

print("OK view")
