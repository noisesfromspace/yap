package tools

import (
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
	if !strings.Contains(r, "[truncated: use offset/limit; file has 2005 lines total]") {
		t.Fatalf("truncation note missing: %.120q", r)
	}
	if strings.Count(r, "\n") != 2000 { // 2000 body lines + the note's own newline
		t.Fatalf("expected 2000 body lines, got %d", strings.Count(r, "\n"))
	}
}

func TestReadSecretPath(t *testing.T) {
	if _, _, err := run(t, "read", `{"path":"~/.ssh/id_ed25519"}`); err == nil || !strings.Contains(err.Error(), "secret path") {
		t.Fatalf("secret path: %v", err)
	}
}
