package tools

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

func TestReadOffsetLimit(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	content := "one\ntwo\nthree\nfour\nfive"
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	r, _, err := run(t, "read", `{"file_path":"`+p+`","offset":2,"limit":2}`)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.HasPrefix(r, "two\nthree") || !strings.Contains(r, "lines 2-3 of 5; continue with offset=4") {
		t.Fatalf("offset/limit: %q", r)
	}

	// a page that ends at EOF reports the final line number, not a truncation note
	r, _, err = run(t, "read", `{"file_path":"`+p+`","offset":4,"limit":2}`)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.HasPrefix(r, "four\nfive") || !strings.Contains(r, "[lines 4-5 of 5]") {
		t.Fatalf("eof page: %q", r)
	}
}

func TestReadPathAlias(t *testing.T) {
	// `path` remains a deprecated alias for `file_path`.
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("one\ntwo\nthree"), 0o644); err != nil {
		t.Fatal(err)
	}
	r, _, err := run(t, "read", `{"path":"`+p+`","offset":2,"limit":1}`)
	if err != nil || !strings.HasPrefix(r, "two") {
		t.Fatalf("path alias: %q %v", r, err)
	}
}

func TestReadMissingPath(t *testing.T) {
	if _, _, err := run(t, "read", `{"offset":1}`); err == nil || !strings.Contains(err.Error(), "file_path is required") {
		t.Fatalf("missing path: %v", err)
	}
}

func TestReadPastEnd(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("one\ntwo\nthree"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := run(t, "read", `{"file_path":"`+p+`","offset":10}`); err == nil || !strings.Contains(err.Error(), "past end of file") {
		t.Fatalf("past end: %v", err)
	}
}

func TestReadTruncation(t *testing.T) {
	p := filepath.Join(t.TempDir(), "big.txt")
	content := strings.TrimSuffix(strings.Repeat("line\n", 2005), "\n")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	r, _, err := run(t, "read", `{"file_path":"`+p+`"}`)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.Contains(r, "[truncated: lines 1-2000 of 2005; continue with offset=2001]") {
		t.Fatalf("truncation note missing the next offset: %.160q", r)
	}
	if strings.Count(r, "\n") != 2000 { // 2000 body lines + the note's own newline
		t.Fatalf("expected 2000 body lines, got %d", strings.Count(r, "\n"))
	}
}

// The byte cap can stop inside the window: the note must point at the line the
// returned text actually ends on, not at the end of the window.
func TestReadByteCapReportsRealLastLine(t *testing.T) {
	p := filepath.Join(t.TempDir(), "wide.txt")
	line := strings.Repeat("x", 200)
	lines := make([]string, 400) // 400 x 201 bytes > readMaxBytes
	for i := range lines {
		lines[i] = line
	}
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")), 0o644); err != nil {
		t.Fatal(err)
	}

	r, _, err := run(t, "read", `{"file_path":"`+p+`"}`)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	m := regexp.MustCompile(`\[truncated: lines 1-(\d+) of 400; continue with offset=(\d+)\]`).FindStringSubmatch(r)
	if m == nil {
		t.Fatalf("byte-cap note missing: %.160q", r)
	}
	last, _ := strconv.Atoi(m[1])
	next, _ := strconv.Atoi(m[2])
	if next != last+1 {
		t.Fatalf("offset %d does not continue after line %d", next, last)
	}
	if last >= 400 {
		t.Fatalf("reported last line %d, but the response was capped", last)
	}
}

// TestReadSecretPathRule: secret paths are approvable, so read's gate rule
// matches them (the approval happens in the agent loop, not in Run).
func TestReadSecretPathRule(t *testing.T) {
	if reason := Match("read", json.RawMessage(`{"file_path":"~/.ssh/id_ed25519"}`)); reason != "reads a secret path" {
		t.Fatalf("secret path: reason=%q", reason)
	}
	if reason := Match("read", json.RawMessage(`{"path":"~/.ssh/id_ed25519"}`)); reason != "reads a secret path" {
		t.Fatalf("secret path via alias: reason=%q", reason)
	}
	if reason := Match("read", json.RawMessage(`{"file_path":"/tmp/ok.txt"}`)); reason != "" {
		t.Fatalf("non-secret path: reason=%q", reason)
	}
	// The :LINE-range suffix must not hide a secret path from the gate.
	if reason := Match("read", json.RawMessage(`{"file_path":"~/.ssh/id_ed25519:1-5"}`)); reason != "reads a secret path" {
		t.Fatalf("ranged secret path: reason=%q", reason)
	}
}

func TestReadPathRangeSuffix(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	content := "one\ntwo\nthree\nfour\nfive"
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	r, _, err := run(t, "read", `{"file_path":"`+p+`:2-4"}`)
	if err != nil {
		t.Fatalf("read path range: %v", err)
	}
	if !strings.HasPrefix(r, "two\nthree\nfour") || !strings.Contains(r, "[lines 2-4 of 5]") {
		t.Fatalf("path :2-4: %q", r)
	}
}

func TestReadRangeForms(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	content := "one\ntwo\nthree\nfour\nfive"
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		suffix string
		want   string
		note   string
	}{
		{":3", "three", "[lines 3-3 of 5]"},
		{":3-", "three\nfour\nfive", "[lines 3-5 of 5]"},
		{":-3", "one\ntwo\nthree", "[lines 1-3 of 5]"},
	}
	for _, c := range cases {
		r, _, err := run(t, "read", `{"file_path":"`+p+c.suffix+`"}`)
		if err != nil {
			t.Fatalf("read %q: %v", c.suffix, err)
		}
		if !strings.HasPrefix(r, c.want) || !strings.Contains(r, c.note) {
			t.Fatalf("range %q: %q", c.suffix, r)
		}
	}
}

// A :LINE suffix on the path is an explicit selection and wins over any
// offset/limit, instead of erroring: the model combines selectors constantly,
// and the suffix is unambiguous.
func TestReadSuffixOverridesOffsetLimit(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("one\ntwo\nthree\nfour\nfive"), 0o644); err != nil {
		t.Fatal(err)
	}
	r, _, err := run(t, "read", `{"file_path":"`+p+`:2-3","offset":1,"limit":5}`)
	if err != nil {
		t.Fatalf("suffix+offset should normalize, not error: %v", err)
	}
	if !strings.HasPrefix(r, "two\nthree") || !strings.Contains(r, "[lines 2-3 of 5]") {
		t.Fatalf("suffix should win: %q", r)
	}
}

func TestReadRangePastEnd(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("one\ntwo\nthree"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := run(t, "read", `{"file_path":"`+p+`:4-6"}`); err == nil || !strings.Contains(err.Error(), "past end of file") {
		t.Fatalf("range past end: %v", err)
	}
}

// The old `range` field is gone: a model that still emits it gets a clean
// validation error pointing at the canonical offset/limit interface.
func TestReadRejectsRangeField(t *testing.T) {
	if _, _, err := run(t, "read", `{"file_path":"/tmp/x","range":"1-2"}`); err == nil || !strings.Contains(err.Error(), "additional properties") {
		t.Fatalf("range field should fail schema validation: %v", err)
	}
}
