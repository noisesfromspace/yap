package utils

import (
	"os"
	"path/filepath"
	"testing"
)

func TestExpandHome(t *testing.T) {
	h, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}

	// ~ and ~/ expand to the home directory
	if got := ExpandHome("~"); got != h {
		t.Fatalf("bare ~: got %q want %q", got, h)
	}
	if got := ExpandHome("~/x.py"); got != filepath.Join(h, "x.py") {
		t.Fatalf("~/path: got %q", got)
	}

	// non-~ paths pass through unchanged (absolute, relative, ~user/)
	for _, p := range []string{"/etc/passwd", "foo.py", "~someone/x"} {
		if got := ExpandHome(p); got != p {
			t.Fatalf("pass-through %q: got %q", p, got)
		}
	}
}

func TestResolvePath(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "real")
	if err := os.Mkdir(real, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}

	// an existing symlinked path resolves
	got, err := ResolvePath(filepath.Join(link, "sub", "f.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(real, "sub", "f.txt"); got != want {
		t.Fatalf("resolve: got %q want %q", got, want)
	}

	// a non-existent leaf resolves its existing ancestors and keeps the tail
	got, err = ResolvePath(filepath.Join(dir, "missing", "f.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, "missing", "f.txt"); got != want {
		t.Fatalf("resolve tail: got %q want %q", got, want)
	}
}
