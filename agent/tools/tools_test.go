package tools

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"boers.email/yap/agent/utils"
)

func run(t *testing.T, tool, args string) (string, string, error) {
	t.Helper()
	tl, ok := Get(tool)
	if !ok {
		t.Fatalf("%s not registered", tool)
	}
	return tl.Run(json.RawMessage(args))
}

func TestBash(t *testing.T) {
	// basic + exit code reported as text, not a tool error
	r, _, err := run(t, "bash", `{"command":"echo hello; exit 3"}`)
	if err != nil || !strings.Contains(r, "hello") || !strings.Contains(r, "[exit code 3]") {
		t.Fatalf("basic: %q %v", r, err)
	}

	// stderr merged into the same output
	r, _, _ = run(t, "bash", `{"command":"echo out; echo err >&2"}`)
	if !strings.Contains(r, "out") || !strings.Contains(r, "err") {
		t.Fatalf("stderr merge: %q", r)
	}

	// timeout kills the whole process group (background sleeper included)
	start := time.Now()
	r, _, _ = run(t, "bash", `{"command":"sleep 60 & sleep 60", "timeout": 1}`)
	if time.Since(start) > 5*time.Second {
		t.Fatal("timeout took too long")
	}
	if !strings.Contains(r, "timed out") {
		t.Fatalf("no timeout note: %q", r)
	}
	time.Sleep(300 * time.Millisecond)
	out, _ := exec.Command("sh", "-c", "ps -eo stat,args | grep 'sleep 60' | grep -v grep | grep -v defunct").Output()
	if strings.TrimSpace(string(out)) != "" {
		t.Fatalf("orphan sleep processes survived:\n%s", out)
	}

	// tail truncation keeps the LAST lines; full output lands in a temp file
	r, _, _ = run(t, "bash", `{"command":"seq 1 5000"}`)
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
	if _, _, err := run(t, "bash", `{"command":"true","cwd":"/nonexistent"}`); err == nil || !strings.Contains(err.Error(), "does not exist") {
		t.Fatalf("cwd check: %v", err)
	}
	r, _, _ = run(t, "bash", `{"command":"read x; echo got:$x"}`)
	if !strings.Contains(r, "got:") {
		t.Fatalf("stdin not null: %q", r)
	}
}

// The tool_start event announces the temp log the live view tails.
func TestBashToolStartEvent(t *testing.T) {
	var buf bytes.Buffer
	old := utils.SetEventWriter(&buf)
	defer utils.SetEventWriter(old)

	if _, _, err := run(t, "bash", `{"command":"echo hi"}`); err != nil {
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
	if ev.Type != "tool_start" || ev.Name != "bash" || !strings.Contains(ev.Log, "yap-bash-") || ev.Command != "echo hi" {
		t.Fatalf("bad event: %+v", ev)
	}
	if !strings.Contains(lines[1], `"tool_end"`) {
		t.Fatalf("no tool_end event: %q", lines[1])
	}
}

func TestBashTempFileHygiene(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)

	// Small output: Go leaves the untruncated log for the Lua side, which
	// drains the final bytes and then deletes it (tool_end carries log +
	// truncated for that). The result still carries the full text.
	var buf bytes.Buffer
	old := utils.SetEventWriter(&buf)
	r, _, err := run(t, "bash", `{"command":"echo small"}`)
	utils.SetEventWriter(old)
	if err != nil || !strings.Contains(r, "small") {
		t.Fatalf("run: %q %v", r, err)
	}
	left, _ := filepath.Glob(tmp + "/yap-bash-*")
	if len(left) != 1 {
		t.Fatalf("expected the untruncated log to be kept for the drain, got: %v", left)
	}
	if !strings.Contains(buf.String(), `"truncated":false`) {
		t.Fatalf("tool_end should mark the log untruncated: %q", buf.String())
	}

	// Truncated output: exactly one file kept, holding the FULL output.
	os.Remove(left[0])
	run(t, "bash", `{"command":"seq 1 5000"}`)
	left, _ = filepath.Glob(tmp + "/yap-bash-*")
	if len(left) != 1 {
		t.Fatalf("truncated output should keep exactly 1 file: %v", left)
	}
	data, _ := os.ReadFile(left[0])
	if !strings.Contains(string(data), "\n42\n") {
		t.Fatal("kept file lacks full output")
	}
}

func TestWriteEdit(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "a", "b", "f.txt")

	// write creates parents and returns an all-+ diff
	r, ui, err := run(t, "write", `{"path":"`+f+`","content":"alpha\nbeta\ngamma\n"}`)
	if err != nil || !strings.Contains(r, "Successfully wrote 17 bytes") {
		t.Fatalf("write: %q %v", r, err)
	}
	if !strings.Contains(ui, "+alpha") || !strings.Contains(ui, "+gamma") {
		t.Fatalf("create diff: %q", ui)
	}
	data, _ := os.ReadFile(f)
	if string(data) != "alpha\nbeta\ngamma\n" {
		t.Fatalf("content: %q", data)
	}

	// overwrite yields a real ui diff
	_, ui, err = run(t, "write", `{"path":"`+f+`","content":"alpha\nBETA\ngamma\n"}`)
	if err != nil || !strings.Contains(ui, "-beta") || !strings.Contains(ui, "+BETA") {
		t.Fatalf("overwrite ui: %q %v", ui, err)
	}

	// edit: multiple disjoint edits in one call
	r, ui, err = run(t, "edit", `{"path":"`+f+`","edits":[{"oldText":"alpha","newText":"ALPHA"},{"oldText":"gamma","newText":"GAMMA"}]}`)
	if err != nil || !strings.Contains(r, "replaced 2 block(s)") {
		t.Fatalf("edit: %q %v", r, err)
	}
	data, _ = os.ReadFile(f)
	if string(data) != "ALPHA\nBETA\nGAMMA\n" {
		t.Fatalf("edit result: %q", data)
	}
	if !strings.Contains(ui, "-alpha") || !strings.Contains(ui, "+GAMMA") {
		t.Fatalf("edit ui: %q", ui)
	}

	// a newText containing another edit's oldText must not cross-match
	f2 := filepath.Join(dir, "f2.txt")
	os.WriteFile(f2, []byte("x y"), 0o644)
	_, _, err = run(t, "edit", `{"path":"`+f2+`","edits":[{"oldText":"x","newText":"y z"},{"oldText":"y","newText":"w"}]}`)
	if err != nil {
		t.Fatalf("cross-match edit: %v", err)
	}
	data, _ = os.ReadFile(f2)
	if string(data) != "y z w" {
		t.Fatalf("cross-match result: %q (want 'y z w')", data)
	}

	// errors: not found, ambiguous, overlap, missing file, empty edits
	cases := []struct{ args, want string }{
		{`{"path":"` + f2 + `","edits":[{"oldText":"nope","newText":"x"}]}`, "not found"},
		{`{"path":"` + f2 + `","edits":[{"oldText":" ","newText":"_"}]}`, "matches 2 times"},
		{`{"path":"` + f2 + `","edits":[{"oldText":"y z","newText":"a"},{"oldText":"z w","newText":"b"}]}`, "overlaps"},
		{`{"path":"` + filepath.Join(dir, "missing.txt") + `","edits":[{"oldText":"a","newText":"b"}]}`, "use write to create"},
		{`{"path":"` + f2 + `","edits":[]}`, "no edits"},
	}
	for _, c := range cases {
		if _, _, err := run(t, "edit", c.args); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Fatalf("edit error case %q: got %v", c.want, err)
		}
	}
}

func TestSchemasAndValidation(t *testing.T) {
	// generated schemas are valid JSON; edit's mentions oldText; no leaks
	for _, name := range []string{"bash", "curl", "edit", "fetch", "glob", "jev", "ls", "quickfix", "read", "search", "websearch", "write"} {
		tl, ok := Get(name)
		if !ok {
			t.Fatalf("%s not registered", name)
		}
		var s map[string]any
		if err := json.Unmarshal(tl.Schema, &s); err != nil {
			t.Fatalf("schema %s: %v", name, err)
		}
		if s["$schema"] != nil {
			t.Fatalf("$schema key leaked in %s", name)
		}
	}
	tl, _ := Get("edit")
	if !strings.Contains(string(tl.Schema), "oldText") {
		t.Fatal("edit schema missing oldText")
	}

	// missing required field / wrong type: model-friendly validation error
	if _, _, err := run(t, "bash", `{"timeout": 5}`); err == nil ||
		!strings.Contains(err.Error(), "invalid arguments") || !strings.Contains(err.Error(), "command") {
		t.Fatalf("required-field validation: %v", err)
	}
	if _, _, err := run(t, "bash", `{"command": 42}`); err == nil || !strings.Contains(err.Error(), "invalid arguments") {
		t.Fatalf("type validation: %v", err)
	}
	if _, _, err := run(t, "edit", `{"path":"/tmp/x"}`); err == nil || !strings.Contains(err.Error(), "edits") {
		t.Fatalf("edit validation: %v", err)
	}
}

func TestUnifiedDiff(t *testing.T) {
	f := filepath.Join(t.TempDir(), "d1.txt")
	os.WriteFile(f, []byte("one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n"), 0o644)
	_, ui, err := run(t, "edit", `{"path":"`+f+`","edits":[{"oldText":"two","newText":"TWO"},{"oldText":"nine","newText":"NINE"}]}`)
	if err != nil {
		t.Fatalf("edit for diff: %v", err)
	}
	if !strings.Contains(ui, "--- a/"+f) {
		t.Fatalf("label: %q", ui)
	}
	// two changes far apart: two separate hunks
	if !strings.Contains(ui, "@@ -1,5 +1,5 @@") || !strings.Contains(ui, "@@ -6,5 +6,5 @@") {
		t.Fatalf("hunk headers: %q", ui)
	}
	for _, want := range []string{"-two", "+TWO", "-nine", "+NINE"} {
		if !strings.Contains(ui, want) {
			t.Fatalf("diff missing %q: %q", want, ui)
		}
	}
}

func TestSearch(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "sub"), 0o755)
	os.WriteFile(filepath.Join(dir, "a.go"), []byte("package x\nfunc Foo() {}\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "sub", "b.go"), []byte("package y\nfunc Foo() {}\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "note.txt"), []byte("Foo here\n"), 0o644)

	// matches across files as path:line:content
	r, _, err := run(t, "search", `{"pattern":"Foo","path":"`+dir+`"}`)
	if err != nil || !strings.Contains(r, "a.go:2:func Foo") || !strings.Contains(r, "b.go:2:func Foo") || !strings.Contains(r, "note.txt") {
		t.Fatalf("search across files: %q %v", r, err)
	}

	// --glob filters by filename
	r, _, err = run(t, "search", `{"pattern":"Foo","path":"`+dir+`","glob":"*.go"}`)
	if err != nil || strings.Contains(r, "note.txt") {
		t.Fatalf("glob filter: %q %v", r, err)
	}

	// no matches is a valid, empty result (rg exit 1), not an error
	r, _, err = run(t, "search", `{"pattern":"zzznope","path":"`+dir+`"}`)
	if err != nil || !strings.Contains(r, "no matches") {
		t.Fatalf("no matches: %q %v", r, err)
	}

	// blank pattern is a tool error
	if _, _, err := run(t, "search", `{"pattern":"   "}`); err == nil || !strings.Contains(err.Error(), "empty pattern") {
		t.Fatalf("blank pattern: %v", err)
	}
}

// TestToolsOnlyToolFiles guards the package layout: every non-test .go file
// except tools.go (the registry) must call Register — i.e. define a tool.
// Helpers that tools need belong in agent/utils, not here.
func TestToolsOnlyToolFiles(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || strings.HasSuffix(name, "_test.go") || name == "tools.go" {
			continue
		}
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(data), "Register(") {
			t.Errorf("%s: non-tool file in agent/tools — helpers belong in agent/utils", name)
		}
	}
}

func TestGlob(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "sub"), 0o755)
	os.WriteFile(filepath.Join(dir, "a.go"), nil, 0o644)
	os.WriteFile(filepath.Join(dir, "sub", "b.go"), nil, 0o644)
	os.WriteFile(filepath.Join(dir, "note.txt"), nil, 0o644)

	// ** recursion finds nested files, excludes non-matching
	r, _, err := run(t, "glob", `{"pattern":"**/*.go","path":"`+dir+`"}`)
	if err != nil || !strings.Contains(r, "a.go") || !strings.Contains(r, "sub/b.go") || strings.Contains(r, "note.txt") {
		t.Fatalf("glob: %q %v", r, err)
	}

	// no matches is a valid, empty result
	r, _, err = run(t, "glob", `{"pattern":"*.zzz","path":"`+dir+`"}`)
	if err != nil || !strings.Contains(r, "no matches") {
		t.Fatalf("glob no matches: %q %v", r, err)
	}
}
