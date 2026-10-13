package tools

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// mustGit runs git in dir with a fixed identity (needed for commits).
func mustGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %s (%v)", args, out, err)
	}
}

// newGitRepo returns a temp repo with one commit ("first" adding a.go),
// an unstaged edit to a.go, and an untracked b.go.
func newGitRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	mustGit(t, dir, "init", "-q")
	mustGit(t, dir, "config", "user.name", "t")
	mustGit(t, dir, "config", "user.email", "t@example.com")
	if err := os.WriteFile(filepath.Join(dir, "a.go"), []byte("package x\n\nfunc A() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mustGit(t, dir, "add", "a.go")
	mustGit(t, dir, "commit", "-qm", "first")
	if err := os.WriteFile(filepath.Join(dir, "a.go"), []byte("package x\n\nfunc A() { return }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "b.go"), []byte("package x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

// chdirGit moves the test process into dir for the duration of the test
// (the git tool runs in the process cwd, which is the project root).
func chdirGit(t *testing.T, dir string) {
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

func TestGit(t *testing.T) {
	chdirGit(t, newGitRepo(t))

	// status: branch header + modified a.go + untracked b.go
	r, _, err := run(t, "git", `{"command":"status"}`)
	if err != nil || !strings.Contains(r, "a.go") || !strings.Contains(r, "b.go") || !strings.Contains(r, "## ") {
		t.Fatalf("status: %q %v", r, err)
	}

	// diff (unstaged): the a.go edit, not the untracked b.go
	r, _, err = run(t, "git", `{"command":"diff"}`)
	if err != nil || !strings.Contains(r, "func A() { return }") || strings.Contains(r, "b.go") {
		t.Fatalf("diff: %q %v", r, err)
	}

	// staged diff: nothing staged yet
	r, _, err = run(t, "git", `{"command":"diff","staged":true}`)
	if err != nil || !strings.Contains(r, "(no changes)") {
		t.Fatalf("staged diff: %q %v", r, err)
	}

	// diff restricted to a path
	r, _, err = run(t, "git", `{"command":"diff","path":"a.go"}`)
	if err != nil || !strings.Contains(r, "func A() { return }") {
		t.Fatalf("diff path: %q %v", r, err)
	}

	// log oneline: the first commit, no full-body noise
	r, _, err = run(t, "git", `{"command":"log","oneline":true}`)
	if err != nil || !strings.Contains(r, "first") || strings.Contains(r, "func A() {}") {
		t.Fatalf("log oneline: %q %v", r, err)
	}

	// show: commit message and its added line
	r, _, err = run(t, "git", `{"command":"show","rev":"HEAD"}`)
	if err != nil || !strings.Contains(r, "first") || !strings.Contains(r, "func A() {}") {
		t.Fatalf("show: %q %v", r, err)
	}

	// blame: current a.go content (uncommitted line attributed to the
	// working tree, committed lines to the first commit)
	r, _, err = run(t, "git", `{"command":"blame","path":"a.go"}`)
	if err != nil || !strings.Contains(r, "func A() { return }") {
		t.Fatalf("blame: %q %v", r, err)
	}

	// blame requires a path
	if _, _, err := run(t, "git", `{"command":"blame"}`); err == nil || !strings.Contains(err.Error(), "blame requires a path") {
		t.Fatalf("blame path: %v", err)
	}
}

func TestGitRevRejectsOption(t *testing.T) {
	chdirGit(t, newGitRepo(t))

	// A rev with a leading dash would be parsed as a git option (and, for
	// diff, is a write/exec primitive: --output writes a file, --ext-diff
	// re-enables external diff drivers). It must be rejected before argv.
	for _, cmd := range []string{"diff", "log", "show"} {
		_, _, err := run(t, "git", `{"command":"`+cmd+`","rev":"--output=/tmp/yap-inject"}`)
		if err == nil || !strings.Contains(err.Error(), "must not start with '-'") {
			t.Fatalf("%s: rev option not rejected: %v", cmd, err)
		}
	}
	// blame takes a rev too and requires a path.
	if _, _, err := run(t, "git", `{"command":"blame","rev":"--ext-diff","path":"a.go"}`); err == nil || !strings.Contains(err.Error(), "must not start with '-'") {
		t.Fatalf("blame: rev option not rejected: %v", err)
	}
}

func TestGitCleanStatus(t *testing.T) {
	dir := newGitRepo(t)
	chdirGit(t, dir)
	mustGit(t, dir, "add", "-A")
	mustGit(t, dir, "commit", "-qm", "second")

	r, _, err := run(t, "git", `{"command":"status"}`)
	if err != nil || !strings.Contains(r, "(clean working tree)") {
		t.Fatalf("clean status: %q %v", r, err)
	}
}

func TestGitNotARepo(t *testing.T) {
	chdirGit(t, t.TempDir())
	if _, _, err := run(t, "git", `{"command":"status"}`); err == nil || !strings.Contains(err.Error(), "not a git repository") {
		t.Fatalf("not a repo: %v", err)
	}
}
