package tools

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLsSorted(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"b.txt", "a.txt"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// "sub" is a directory so ls appends a trailing slash
	if err := os.WriteFile(filepath.Join(dir, "sub", "placeholder"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	r, _, err := run(t, "ls", `{"path":"`+dir+`"}`)
	if err != nil {
		t.Fatalf("ls: %v", err)
	}
	if r != "a.txt\nb.txt\nsub/" {
		t.Fatalf("sorted listing: %q", r)
	}
}

func TestLsCap(t *testing.T) {
	dir := t.TempDir()
	for i := 0; i < 2001; i++ {
		if err := os.Mkdir(filepath.Join(dir, fmt.Sprintf("d%04d", i)), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	r, _, err := run(t, "ls", `{"path":"`+dir+`"}`)
	if err != nil {
		t.Fatalf("ls: %v", err)
	}
	if !strings.Contains(r, "[truncated: narrow the path or use glob]") {
		t.Fatalf("cap note missing: %.120q", r)
	}
	if strings.Count(r, "\n") != 2000 { // 2000 entry lines + the note's own newline
		t.Fatalf("expected 2000 entry lines, got %d", strings.Count(r, "\n"))
	}
}
