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

	"boers.email/yap/agent/wire"
)

func run(t *testing.T, tool, args string) (string, string, error) {
	t.Helper()
	tl, ok := Get(tool)
	if !ok {
		t.Fatalf("%s not registered", tool)
	}
	return tl.Run(json.RawMessage(args))
}

// approvalIDWriter replies to the ID actually emitted by RequestApproval,
// avoiding assumptions about process-global approval sequence state.
type approvalIDWriter struct{ ids chan string }

func (w approvalIDWriter) Write(p []byte) (int, error) {
	var ev struct {
		Type string `json:"type"`
		ID   string `json:"id"`
	}
	if json.Unmarshal(p, &ev) == nil && ev.Type == "approval_request" {
		w.ids <- ev.ID
	}
	return len(p), nil
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

// The tool_start event announces the temp log the live view follows; the
// tool_output frames stream its bytes; tool_end closes it. All three land on
// one ordered channel.
func TestBashToolStartEvent(t *testing.T) {
	var buf bytes.Buffer
	old := wire.SetFrameWriter(&buf)
	defer wire.SetFrameWriter(old)

	if _, _, err := run(t, "bash", `{"command":"echo hi"}`); err != nil {
		t.Fatalf("run: %v", err)
	}
	var started, ended, streamed bool
	var startEv struct {
		Type    string `json:"type"`
		Name    string `json:"name"`
		Log     string `json:"log"`
		Command string `json:"command"`
	}
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		var outer struct {
			Type  string          `json:"type"`
			Event json.RawMessage `json:"event"`
		}
		if err := json.Unmarshal([]byte(line), &outer); err != nil {
			t.Fatalf("frame not JSON: %q", line)
		}
		switch outer.Type {
		case "event":
			var ev struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(outer.Event, &ev) != nil {
				continue
			}
			switch ev.Type {
			case "tool_start":
				started = true
				_ = json.Unmarshal(outer.Event, &startEv)
			case "tool_end":
				ended = true
			}
		case "tool_output":
			streamed = true
		}
	}
	if !started || !ended || !streamed {
		t.Fatalf("expected tool_start, tool_output and tool_end frames, got: %q", buf.String())
	}
	if startEv.Type != "tool_start" || startEv.Name != "bash" || !strings.Contains(startEv.Log, "yap-bash-") || startEv.Command != "echo hi" {
		t.Fatalf("bad tool_start event: %+v", startEv)
	}
}

func TestBashTerminalOutput(t *testing.T) {
	var frames bytes.Buffer
	old := wire.SetFrameWriter(&frames)
	defer wire.SetFrameWriter(old)

	// Split an escape sequence across writes; progress updates use CR to
	// replace the current line, not append hundreds of control characters.
	result, _, err := run(t, "bash", `{"command":"printf 'tests/suite.lua: \\033[1;32mo\\033[0m\\r\\033['; sleep 0.02; printf '1;32mo\\033[0m\\nUTF-8: café\\n'"}`)
	want := "o\nUTF-8: café\n"
	if err != nil || result != want {
		t.Fatalf("result = %q, %v; want %q", result, err, want)
	}
	var streamed strings.Builder
	for _, line := range strings.Split(strings.TrimSpace(frames.String()), "\n") {
		var frame struct {
			Type  string `json:"type"`
			Delta string `json:"delta"`
		}
		if json.Unmarshal([]byte(line), &frame) == nil && frame.Type == "tool_output" {
			streamed.WriteString(frame.Delta)
		}
	}
	if streamed.String() != want {
		t.Fatalf("live output = %q; want %q", streamed.String(), want)
	}
}

func TestGuardRules(t *testing.T) {
	// Dangerous bash commands produce a guard-rule reason.
	if reason := Match("bash", json.RawMessage(`{"command":"rm -rf /"}`)); reason == "" {
		t.Fatalf("bash rm -rf /: no rule matched")
	}
	if reason := Match("bash", json.RawMessage(`{"command":"sudo apt update"}`)); reason != "sudo" {
		t.Fatalf("bash sudo: reason=%q", reason)
	}

	// Benign commands are not gated.
	if reason := Match("bash", json.RawMessage(`{"command":"echo hi"}`)); reason != "" {
		t.Fatalf("echo hi: reason=%q", reason)
	}

	// ssh always requires approval.
	if reason := Match("ssh", json.RawMessage(`{"host":"db","command":"restart"}`)); reason != "remote command execution" {
		t.Fatalf("ssh: reason=%q", reason)
	}

	// Secret paths are approvable for read/write/edit/search: a matching rule,
	// never a silent read/write.
	for _, tc := range []struct{ tool, args, want string }{
		{"read", `{"path":"~/.ssh/id_ed25519"}`, "reads a secret path"},
		{"write", `{"path":"~/.aws/credentials"}`, "writes a secret path"},
		{"edit", `{"path":"~/.config/sops/age.yaml"}`, "edits a secret path"},
		{"search", `{"pattern":"x","path":"/run/agenix.d"}`, "searches a secret path"},
	} {
		if reason := Match(tc.tool, json.RawMessage(tc.args)); reason != tc.want {
			t.Fatalf("%s: reason=%q want %q", tc.tool, reason, tc.want)
		}
	}
	if reason := Match("write", json.RawMessage(`{"path":"/tmp/out.txt"}`)); reason != "" {
		t.Fatalf("write non-secret path: reason=%q", reason)
	}

	// write/edit are project-bound: a target outside the writable allowlist
	// (project + assets + temp) pauses, mirroring the bash sandbox's write
	// barrier. read is deliberately NOT bounded — reading is not a write.
	if reason := Match("write", json.RawMessage(`{"path":"/etc/hostname"}`)); reason != "write target outside allowed write paths (pre-run)" {
		t.Fatalf("write outside project: reason=%q", reason)
	}
	if reason := Match("edit", json.RawMessage(`{"path":"/etc/hostname"}`)); reason != "edit target outside allowed write paths (pre-run)" {
		t.Fatalf("edit outside project: reason=%q", reason)
	}
	if reason := Match("read", json.RawMessage(`{"path":"/etc/hostname"}`)); reason != "" {
		t.Fatalf("read outside project should not be bounded: reason=%q", reason)
	}

	// curl gates its exfiltration vectors: an explicit non-GET method or a
	// request body. Plain GET/HEAD fetches run.
	if reason := Match("curl", json.RawMessage(`{"url":"https://example.com"}`)); reason != "" {
		t.Fatalf("curl GET: reason=%q", reason)
	}
	if reason := Match("curl", json.RawMessage(`{"url":"https://example.com","method":"POST"}`)); reason != "non-GET request method" {
		t.Fatalf("curl POST: reason=%q", reason)
	}
	if reason := Match("curl", json.RawMessage(`{"url":"https://example.com","data":"x"}`)); reason != "sends a request body" {
		t.Fatalf("curl body: reason=%q", reason)
	}
	if reason := Match("curl", json.RawMessage(`{"url":"https://example.com","flags":"-o /tmp/x"}`)); reason != "reads or writes a local file" {
		t.Fatalf("curl output flag: reason=%q", reason)
	}
	if reason := Match("curl", json.RawMessage(`{"url":"https://example.com","flags":"-d @/etc/hostname"}`)); reason != "reads or writes a local file" {
		t.Fatalf("curl @file flag: reason=%q", reason)
	}
	// SSRF/protocol flags are hard-refused in the tool, not approval-gated.
	if reason := Match("curl", json.RawMessage(`{"url":"https://example.com","flags":"--resolve x:80:127.0.0.1"}`)); reason != "" {
		t.Fatalf("curl SSRF flag should be refused, not gated: reason=%q", reason)
	}

	// subagent delegates to a child whose own tools carry the gates: no rule.
	if reason := Match("subagent", json.RawMessage(`{"agent":"audit","task":"x"}`)); reason != "" {
		t.Fatalf("subagent: reason=%q", reason)
	}

	// playwright gates only the eval command (arbitrary JavaScript).
	if reason := Match("playwright", json.RawMessage(`{"command":"eval document.cookie"}`)); reason != "browser JavaScript eval" {
		t.Fatalf("playwright eval: reason=%q", reason)
	}
	if reason := Match("playwright", json.RawMessage(`{"command":"goto https://example.com"}`)); reason != "" {
		t.Fatalf("playwright goto: reason=%q", reason)
	}

	// Unknown and ungated tools run.
	if reason := Match("nope", json.RawMessage(`{}`)); reason != "" {
		t.Fatalf("unknown tool: reason=%q", reason)
	}
	if reason := Match("read", json.RawMessage(`{}`)); reason != "" {
		t.Fatalf("read: reason=%q", reason)
	}
}

func TestGuardRulesListing(t *testing.T) {
	// Rules() is the `yap guard` source: sorted by (tool, name), with the
	// always flag set only for ssh (the one unconditional-approval tool).
	sawSSH := false
	var prev string
	for _, r := range Rules() {
		if r.Tool+"/"+r.Name < prev {
			t.Fatalf("rules not sorted: %q before %q", prev, r.Tool+"/"+r.Name)
		}
		prev = r.Tool + "/" + r.Name
		if r.Tool == "ssh" {
			sawSSH = true
			if !r.Always {
				t.Fatalf("ssh rule should be marked always")
			}
		}
	}
	if !sawSSH {
		t.Fatal("ssh rule missing from Rules()")
	}
}

func TestBashTempFileHygiene(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)

	// Small output: Go leaves the untruncated log for the Lua side, which
	// drains the final bytes and then deletes it (tool_end carries log +
	// truncated for that). The result still carries the full text.
	var buf bytes.Buffer
	old := wire.SetFrameWriter(&buf)
	r, _, err := run(t, "bash", `{"command":"echo small"}`)
	wire.SetFrameWriter(old)
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
	if err != nil || !strings.Contains(r, "replaced 2 edit(s)") {
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
	for _, name := range []string{"bash", "close_session", "curl", "edit", "fetch", "glob", "models", "quickfix", "read", "search", "websearch", "write"} {
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

func TestCloseSession(t *testing.T) {
	// A no-arg frontend side effect: it registers, accepts `{}`, and returns
	// a confirmation. The buffer close happens on the Neovim side (see
	// init.lua), not here.
	r, ui, err := run(t, "close_session", `{}`)
	if err != nil || !strings.Contains(r, "close requested") || ui != "" {
		t.Fatalf("close_session: %q %q %v", r, ui, err)
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

// TestToolSchemasHaveNoRefs guards against emitting $defs/$ref in generated
// tool schemas: Moonshot's validator rejects a $ref to $defs as "infinite
// recursion without termination condition". Nested structs must be inlined.
func TestToolSchemasHaveNoRefs(t *testing.T) {
	for _, tl := range All() {
		var doc map[string]any
		if err := json.Unmarshal(tl.Schema, &doc); err != nil {
			t.Fatalf("%s: invalid schema: %v", tl.Name, err)
		}
		if _, ok := doc["$defs"]; ok {
			t.Errorf("%s: schema contains $defs; inline nested structs instead", tl.Name)
		}
		if bytes.Contains(tl.Schema, []byte(`"$ref"`)) {
			t.Errorf("%s: schema contains $ref; inline nested structs instead", tl.Name)
		}
	}
}

func TestToolCleanup(t *testing.T) {
	calls := 0
	Register("test_cleanup", "test only", func(_ *struct{}) (string, string, error) {
		return "", "", nil
	}, func() { calls++ })
	defer delete(registry, "test_cleanup")

	CloseAll()
	if calls != 1 {
		t.Fatalf("registered cleanup called %d times, want 1", calls)
	}
	delete(registry, "test_cleanup")
	CloseAll()
	if calls != 1 {
		t.Fatalf("removed tool cleanup called again: %d", calls)
	}
}

// TestToolsOnlyToolFiles guards the package layout: every non-test .go file
// except tools.go (the registry) must define exactly one tool and
// self-register via Register. Tool providers (websearch backends, the
// decision model) live outside this directory and register through
// RegisterWebsearchProvider. Helpers that tools need belong in agent/utils,
// not here.
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
