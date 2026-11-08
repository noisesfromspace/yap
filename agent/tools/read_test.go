package tools

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadOffsetLimit(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	content := "one\ntwo\nthree\nfour\nfive"
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	r, _, err := run(t, "read", `{"path":"`+p+`","offset":2,"limit":2}`)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.HasPrefix(r, "two\nthree") || !strings.Contains(r, "5 lines total") {
		t.Fatalf("offset/limit: %q", r)
	}

	// a page that ends at EOF reports the final line number, not a truncation note
	r, _, err = run(t, "read", `{"path":"`+p+`","offset":4,"limit":2}`)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.HasPrefix(r, "four\nfive") || !strings.Contains(r, "[lines 4-5 of 5]") {
		t.Fatalf("eof page: %q", r)
	}
}

func TestReadPastEnd(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("one\ntwo\nthree"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := run(t, "read", `{"path":"`+p+`","offset":10}`); err == nil || !strings.Contains(err.Error(), "past end of file") {
		t.Fatalf("past end: %v", err)
	}
}

func TestReadTruncation(t *testing.T) {
	p := filepath.Join(t.TempDir(), "big.txt")
	content := strings.TrimSuffix(strings.Repeat("line\n", 2005), "\n")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	r, _, err := run(t, "read", `{"path":"`+p+`"}`)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.Contains(r, "[truncated: use offset/limit or range; file has 2005 lines total]") {
		t.Fatalf("truncation note missing: %.120q", r)
	}
	if strings.Count(r, "\n") != 2000 { // 2000 body lines + the note's own newline
		t.Fatalf("expected 2000 body lines, got %d", strings.Count(r, "\n"))
	}
}

// TestReadSecretPathRule: secret paths are approvable, so read's gate rule
// matches them (the approval happens in the agent loop, not in Run).
func TestReadSecretPathRule(t *testing.T) {
	if reason := Match("read", json.RawMessage(`{"path":"~/.ssh/id_ed25519"}`)); reason != "reads a secret path" {
		t.Fatalf("secret path: reason=%q", reason)
	}
	if reason := Match("read", json.RawMessage(`{"path":"/tmp/ok.txt"}`)); reason != "" {
		t.Fatalf("non-secret path: reason=%q", reason)
	}
	// The :LINE-range suffix must not hide a secret path from the gate.
	if reason := Match("read", json.RawMessage(`{"path":"~/.ssh/id_ed25519:1-5"}`)); reason != "reads a secret path" {
		t.Fatalf("ranged secret path: reason=%q", reason)
	}
}

func TestReadRange(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	content := "one\ntwo\nthree\nfour\nfive"
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	r, _, err := run(t, "read", `{"path":"`+p+`","range":"2-4"}`)
	if err != nil {
		t.Fatalf("read range: %v", err)
	}
	if !strings.HasPrefix(r, "two\nthree\nfour") || !strings.Contains(r, "[lines 2-4 of 5]") {
		t.Fatalf("range 2-4: %q", r)
	}
}

func TestReadPathRangeSuffix(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	content := "one\ntwo\nthree\nfour\nfive"
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	r, _, err := run(t, "read", `{"path":"`+p+`:2-4"}`)
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
		rng  string
		want string
		note string
	}{
		{"3", "three", "[lines 3-3 of 5]"},
		{"3-", "three\nfour\nfive", "[lines 3-5 of 5]"},
		{"-3", "one\ntwo\nthree", "[lines 1-3 of 5]"},
	}
	for _, c := range cases {
		r, _, err := run(t, "read", `{"path":"`+p+`","range":"`+c.rng+`"}`)
		if err != nil {
			t.Fatalf("read range %q: %v", c.rng, err)
		}
		if !strings.HasPrefix(r, c.want) || !strings.Contains(r, c.note) {
			t.Fatalf("range %q: %q", c.rng, r)
		}
	}
}

func TestReadRangeConflicts(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("one\ntwo"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, _, err := run(t, "read", `{"path":"`+p+`","range":"1-2","offset":1}`); err == nil {
		t.Fatal("range+offset: expected error")
	}
	if _, _, err := run(t, "read", `{"path":"`+p+`","range":"1-2","limit":2}`); err == nil {
		t.Fatal("range+limit: expected error")
	}
	if _, _, err := run(t, "read", `{"path":"`+p+`:1-2","range":"1-2"}`); err == nil {
		t.Fatal("range+path suffix: expected error")
	}
}

func TestReadRangePastEnd(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("one\ntwo\nthree"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := run(t, "read", `{"path":"`+p+`","range":"4-6"}`); err == nil || !strings.Contains(err.Error(), "past end of file") {
		t.Fatalf("range past end: %v", err)
	}
}
