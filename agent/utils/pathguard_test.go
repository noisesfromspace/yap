package utils

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// chdir changes the process cwd for the duration of the test (the write
// guard treats the process cwd as the project root).
func chdir(t *testing.T, dir string) {
	t.Helper()
	old, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chdir(old) })
}

func TestGuardReadPath(t *testing.T) {
	h, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	// a normal file is allowed
	f := filepath.Join(t.TempDir(), "ok.txt")
	if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := GuardReadPath(f); err != nil {
		t.Fatalf("normal read blocked: %v", err)
	}

	// direct secret path is blocked
	if err := GuardReadPath(filepath.Join(h, ".ssh", "id_ed25519")); err == nil || !strings.Contains(err.Error(), "secret path") {
		t.Fatalf("direct secret path: %v", err)
	}

	// a symlink into a secret directory is blocked
	dir := t.TempDir()
	link := filepath.Join(dir, "link")
	if err := os.Symlink(filepath.Join(h, ".ssh"), link); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	if err := GuardReadPath(filepath.Join(link, "id_ed25519")); err == nil || !strings.Contains(err.Error(), "secret path") {
		t.Fatalf("symlinked secret path: %v", err)
	}
}

func TestGuardWritePath(t *testing.T) {
	h, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	// secret paths are blocked
	if _, err := GuardWritePath(filepath.Join(h, ".ssh", "authorized_keys")); err == nil || !strings.Contains(err.Error(), "secret path") {
		t.Fatalf("secret write: %v", err)
	}

	// /run/agenix is itself a symlink; the literal path must still block
	if _, err := GuardWritePath("/run/agenix/foo"); err == nil || !strings.Contains(err.Error(), "secret path") {
		t.Fatalf("agenix write: %v", err)
	}

	// writes inside the project root carry no note
	proj := t.TempDir()
	chdir(t, proj)
	if note, err := GuardWritePath(filepath.Join(proj, "a.txt")); err != nil || note != "" {
		t.Fatalf("in-root write: note=%q err=%v", note, err)
	}

	// writes outside the project root are annotated, not blocked
	outside := t.TempDir()
	if note, err := GuardWritePath(filepath.Join(outside, "b.txt")); err != nil || !strings.Contains(note, "outside project root") {
		t.Fatalf("out-of-root write: note=%q err=%v", note, err)
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
	got, err := resolvePath(filepath.Join(link, "sub", "f.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(real, "sub", "f.txt"); got != want {
		t.Fatalf("resolve: got %q want %q", got, want)
	}

	// a non-existent leaf resolves its existing ancestors and keeps the tail
	got, err = resolvePath(filepath.Join(dir, "missing", "f.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, "missing", "f.txt"); got != want {
		t.Fatalf("resolve tail: got %q want %q", got, want)
	}
}
