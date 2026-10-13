package tools

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"boers.email/yap/agent/utils"
)

func TestPython(t *testing.T) {
	// basic + exit code reported as text, not a tool error
	r, _, err := run(t, "python", `{"code":"print('hello'); import sys; sys.exit(3)"}`)
	if err != nil || !strings.Contains(r, "hello") || !strings.Contains(r, "[exit code 3]") {
		t.Fatalf("basic: %q %v", r, err)
	}

	// stderr merged into the same output
	r, _, _ = run(t, "python", `{"code":"print('out'); import sys; print('err', file=sys.stderr)"}`)
	if !strings.Contains(r, "out") || !strings.Contains(r, "err") {
		t.Fatalf("stderr merge: %q", r)
	}

	// a failing script returns its traceback as text
	r, _, _ = run(t, "python", `{"code":"raise ValueError('boom')"}`)
	if !strings.Contains(r, "ValueError") || !strings.Contains(r, "boom") || !strings.Contains(r, "[exit code 1]") {
		t.Fatalf("traceback: %q", r)
	}

	// stateless: a name defined in one call is gone in the next
	run(t, "python", `{"code":"x = 42"}`)
	r, _, _ = run(t, "python", `{"code":"print(x)"}`)
	if !strings.Contains(r, "NameError") {
		t.Fatalf("state leaked between calls: %q", r)
	}

	// timeout kills the whole process group
	start := time.Now()
	r, _, _ = run(t, "python", `{"code":"import time; time.sleep(60)","timeout":1}`)
	if time.Since(start) > 5*time.Second {
		t.Fatal("timeout took too long")
	}
	if !strings.Contains(r, "timed out") {
		t.Fatalf("no timeout note: %q", r)
	}

	// tail truncation keeps the LAST lines; full output lands in a temp file
	r, _, _ = run(t, "python", `{"code":"for i in range(5000): print(i)"}`)
	if !strings.Contains(r, "truncated") || strings.Contains(r, "\n42\n") {
		t.Fatalf("tail truncation wrong: %.120q", r)
	}
	off := strings.Index(r, " at ") + 4
	path := strings.TrimRight(r[off:strings.Index(r[off:], "]")+off], "\n")
	data, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(data), "\n42\n") {
		t.Fatalf("temp file missing full output: %v", err)
	}

	// bad cwd reported as a tool error; stdin is /dev/null (no hang on read)
	if _, _, err := run(t, "python", `{"code":"pass","cwd":"/nonexistent"}`); err == nil || !strings.Contains(err.Error(), "does not exist") {
		t.Fatalf("cwd check: %v", err)
	}
	r, _, _ = run(t, "python", `{"code":"print(input())"}`)
	if !strings.Contains(r, "EOFError") {
		t.Fatalf("stdin not null: %q", r)
	}

	// empty code (after trim) counts as neither code nor file
	if _, _, err := run(t, "python", `{"code":"   "}`); err == nil || !strings.Contains(err.Error(), "code or file") {
		t.Fatalf("empty code: %v", err)
	}
	// neither code nor file, and both, are tool errors
	if _, _, err := run(t, "python", `{}`); err == nil || !strings.Contains(err.Error(), "code or file") {
		t.Fatalf("neither: %v", err)
	}
	if _, _, err := run(t, "python", `{"code":"1","file":"x.py"}`); err == nil || !strings.Contains(err.Error(), "not both") {
		t.Fatalf("both: %v", err)
	}
}

func TestPythonFile(t *testing.T) {
	dir := t.TempDir()
	// write the script the way the model would (relative to cwd), then run
	// it by file reference.
	script := filepath.Join(dir, "gen.py")
	if err := os.WriteFile(script, []byte("print('from file')\nimport sys; sys.exit(4)\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r, _, err := run(t, "python", `{"file":"`+script+`"}`)
	if err != nil || !strings.Contains(r, "from file") || !strings.Contains(r, "[exit code 4]") {
		t.Fatalf("file run: %q %v", r, err)
	}

	// a failing file returns its traceback as text
	if err := os.WriteFile(script, []byte("raise RuntimeError('bad')\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r, _, _ = run(t, "python", `{"file":"`+script+`"}`)
	if !strings.Contains(r, "RuntimeError") || !strings.Contains(r, "bad") {
		t.Fatalf("file traceback: %q", r)
	}

	// missing file and directory are tool errors
	if _, _, err := run(t, "python", `{"file":"`+filepath.Join(dir, "nope.py")+`"}`); err == nil || !strings.Contains(err.Error(), "script file") {
		t.Fatalf("missing file: %v", err)
	}
	if _, _, err := run(t, "python", `{"file":"`+dir+`"}`); err == nil || !strings.Contains(err.Error(), "directory") {
		t.Fatalf("directory: %v", err)
	}
}

func TestPythonWriteFileRoundtrip(t *testing.T) {
	// An isolated $HOME lets us exercise the full `~` path without touching
	// the real home directory: write the script, then run it via `file=`.
	home := t.TempDir()
	t.Setenv("HOME", home)

	script := "~/.local/share/yap/scratch/gen.py"
	if _, _, err := run(t, "write", `{"path":"`+script+`","content":"print('from-file')\n"}`); err != nil {
		t.Fatalf("write: %v", err)
	}
	r, _, err := run(t, "python", `{"file":"`+script+`"}`)
	if err != nil || !strings.Contains(r, "from-file") {
		t.Fatalf("run: %q %v", r, err)
	}
	// the script landed under $HOME, not a literal ~/ dir in the project
	if _, err := os.Stat(filepath.Join(home, ".local", "share", "yap", "scratch", "gen.py")); err != nil {
		t.Fatalf("script not under $HOME: %v", err)
	}
}

func TestPythonFileToolStartLabel(t *testing.T) {
	script := filepath.Join(t.TempDir(), "s.py")
	if err := os.WriteFile(script, []byte("print('x')\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	old := utils.SetEventWriter(&buf)
	defer utils.SetEventWriter(old)

	if _, _, err := run(t, "python", `{"file":"`+script+`"}`); err != nil {
		t.Fatalf("run: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	jsonLine, ok := strings.CutPrefix(lines[0], "yap:event ")
	if !ok {
		t.Fatalf("no yap:event line: %q", lines[0])
	}
	var ev struct {
		Type    string `json:"type"`
		Name    string `json:"name"`
		Command string `json:"command"`
	}
	if err := json.Unmarshal([]byte(jsonLine), &ev); err != nil {
		t.Fatalf("event not JSON: %v", err)
	}
	if ev.Command != "python3 "+script {
		t.Fatalf("command label: %q", ev.Command)
	}
}

func TestPythonToolStartEvent(t *testing.T) {
	var buf bytes.Buffer
	old := utils.SetEventWriter(&buf)
	defer utils.SetEventWriter(old)

	if _, _, err := run(t, "python", `{"code":"print('hi')"}`); err != nil {
		t.Fatalf("run: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected tool_start + tool_end events, got: %q", buf.String())
	}
	jsonLine, ok := strings.CutPrefix(lines[0], "yap:event ")
	if !ok {
		t.Fatalf("no yap:event line: %q", lines[0])
	}
	var ev struct {
		Type    string `json:"type"`
		Name    string `json:"name"`
		Log     string `json:"log"`
		Command string `json:"command"`
	}
	if err := json.Unmarshal([]byte(jsonLine), &ev); err != nil {
		t.Fatalf("event not JSON: %v", err)
	}
	if ev.Type != "tool_start" || ev.Name != "python" || !strings.Contains(ev.Log, "yap-python-") || ev.Command != "python3" {
		t.Fatalf("bad event: %+v", ev)
	}
	if !strings.Contains(lines[1], `"tool_end"`) {
		t.Fatalf("no tool_end event: %q", lines[1])
	}
}

func TestPythonTempFileHygiene(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)

	run(t, "python", `{"code":"print('hi')"}`)

	// the script file is removed once the run returns; only the output log
	// is kept for the Lua side's drain (tool_end carries log + truncated)
	scripts, _ := filepath.Glob(tmp + "/yap-py-*.py")
	if len(scripts) != 0 {
		t.Fatalf("script file should be removed: %v", scripts)
	}
	logs, _ := filepath.Glob(tmp + "/yap-python-*.log")
	if len(logs) != 1 {
		t.Fatalf("expected the untruncated log to be kept for the drain, got: %v", logs)
	}
}
