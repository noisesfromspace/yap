package tools

import (
	"path/filepath"
	"strings"
	"testing"

	"boers.email/yap/agent/utils"
)

func TestBashBasic(t *testing.T) {
	r, _, err := run(t, "bash", `{"command":"echo hello; echo err >&2"}`)
	if err != nil {
		t.Fatalf("bash: %v", err)
	}
	// stdout and stderr are merged into one result
	if !strings.Contains(r, "hello") || !strings.Contains(r, "err") {
		t.Fatalf("merged output: %q", r)
	}
}

func TestBashExitCode(t *testing.T) {
	r, _, err := run(t, "bash", `{"command":"exit 3"}`)
	if err != nil {
		t.Fatalf("bash: %v", err)
	}
	if !strings.Contains(r, "[exit code 3]") {
		t.Fatalf("exit code: %q", r)
	}
}

func TestBashEmptyCommand(t *testing.T) {
	if _, _, err := run(t, "bash", `{"command":"   "}`); err == nil || !strings.Contains(err.Error(), "empty command") {
		t.Fatalf("empty command: %v", err)
	}
}

// Without a cwd argument the command runs in the frontend's cwd, which is
// sent with every turn — the backend process cwd is fixed at spawn and goes
// stale after a :cd.
func TestBashDefaultsToFrontendCwd(t *testing.T) {
	old := utils.FrontendCwd()
	defer utils.SetFrontendCwd(old)
	dir := t.TempDir()
	utils.SetFrontendCwd(dir)
	r, _, err := run(t, "bash", `{"command":"pwd"}`)
	if err != nil {
		t.Fatalf("bash: %v", err)
	}
	// `pwd` reports the resolved path, which may differ from the temp dir
	// when the temp root itself is a symlink.
	want, err := filepath.EvalSymlinks(dir)
	if err != nil {
		want = dir
	}
	if !strings.Contains(r, want) {
		t.Fatalf("cwd not applied: %q (want %s)", r, want)
	}
	// an explicit cwd still wins
	other := t.TempDir()
	r, _, err = run(t, "bash", `{"command":"pwd","cwd":"`+other+`"}`)
	if err != nil || !strings.Contains(r, other) {
		t.Fatalf("explicit cwd: %q %v", r, err)
	}
}
