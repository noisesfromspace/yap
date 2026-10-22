package safety

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"boers.email/yap/agent/utils"
)

// reset clears the sandbox policy and availability cache so tests are isolated.
func reset() {
	sandboxPolicy = SandboxConfig{}
	sandboxAvail = -1
	sandboxWarned = false
}

func requireBwrap(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("bwrap not installed")
	}
	if err := probe(); err != nil {
		t.Skipf("bwrap unusable: %v", err)
	}
}

func TestSandboxViolated(t *testing.T) {
	if !SandboxViolated("sh: line 1: /etc/x: Read-only file system\n[exit code 1]") {
		t.Fatal("expected a write-barrier violation")
	}
	if SandboxViolated("hello world") {
		t.Fatal("false positive on ordinary output")
	}
}

func TestSandboxActiveRespectsDisabled(t *testing.T) {
	reset()
	SetSandboxConfig(SandboxConfig{Enabled: false})
	if SandboxActive() {
		t.Fatal("disabled sandbox should not be active")
	}
}

func TestWritableDirs(t *testing.T) {
	reset()
	assets := t.TempDir()
	utils.SetAssetsBase(assets)
	defer utils.SetAssetsBase("")

	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	sandboxPolicy = SandboxConfig{AllowWrite: []string{"~/cache"}}

	got := WritableDirs("/srv/proj")
	want := map[string]bool{
		"/srv/proj":                  true,
		assets:                       true,
		filepath.Join(home, "cache"): true,
	}
	for _, g := range got {
		if !want[g] {
			t.Fatalf("unexpected writable dir %q", g)
		}
		delete(want, g)
	}
	if len(want) != 0 {
		t.Fatalf("missing writable dirs: %v", want)
	}

	// "/" and the temp dir are never writable (the temp dir is the private tmpfs).
	got = WritableDirs("/")
	for _, g := range got {
		if g == "/" || g == os.TempDir() || g == "/tmp" {
			t.Fatalf("forbidden writable dir %q", g)
		}
	}
}

func TestShadowPaths(t *testing.T) {
	reset()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	sandboxPolicy = SandboxConfig{DenyRead: []string{"~/private"}}
	paths := shadowPaths()

	want := map[string]bool{
		filepath.Join(home, "private"): true, // the configured extra, ~-expanded
		filepath.Join(home, ".ssh"):    true, // a built-in secret dir
	}
	for _, p := range paths {
		delete(want, p)
	}
	if len(want) != 0 {
		t.Fatalf("expected shadow paths missing: %v (got %v)", want, paths)
	}
}

// File deny-read entries must be shadowed too, not only directories.
func TestSandboxShadowsConfiguredFile(t *testing.T) {
	reset()
	project := t.TempDir()
	secret := filepath.Join(project, "token")
	if err := os.WriteFile(secret, []byte("private"), 0o600); err != nil {
		t.Fatal(err)
	}
	SetSandboxConfig(SandboxConfig{Enabled: true, DenyRead: []string{secret}})
	args := sandboxSetup(project)
	found := false
	for i := 0; i+2 < len(args); i++ {
		if args[i] == "--ro-bind" && args[i+1] == "/dev/null" && args[i+2] == secret {
			found = true
		}
	}
	if !found {
		t.Fatalf("deny-read file not shadowed by /dev/null: %v", args)
	}
	t.Run("runtime", func(t *testing.T) {
		requireBwrap(t)
		out, err := SandboxWrap("cat "+secret+"; echo done", project).CombinedOutput()
		if err != nil || strings.Contains(string(out), "private") || !strings.Contains(string(out), "done") {
			t.Fatalf("file shadow failed: %q (%v)", out, err)
		}
	})
}

func TestSandboxWrapArgs(t *testing.T) {
	reset()
	cmd := SandboxWrap("echo hi", "/srv/proj")
	args := cmd.Args[1:] // drop "bwrap"
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "--ro-bind / /") {
		t.Fatalf("missing read-only root: %v", args)
	}
	if !strings.Contains(joined, "--tmpfs "+os.TempDir()) {
		t.Fatalf("missing private tmpfs: %v", args)
	}
	if !strings.Contains(joined, "--bind /srv/proj /srv/proj") {
		t.Fatalf("missing project bind: %v", args)
	}
	// the command runs after the `--` separator
	last := args[len(args)-4:]
	if last[0] != "--" || last[1] != "bash" || last[2] != "-c" {
		t.Fatalf("expected `-- bash -c`, got %v", last)
	}
	if last[3] != "echo hi" {
		t.Fatalf("expected the command last, got %q", last[3])
	}
}

// TestWrapEnforcesWriteBarrier runs bwrap end to end: writes outside the
// allowlist fail with EROFS, writes to the project dir succeed.
func TestWrapEnforcesWriteBarrier(t *testing.T) {
	requireBwrap(t)
	reset()
	project := t.TempDir()
	SetSandboxConfig(SandboxConfig{Enabled: true})

	out, err := SandboxWrap("echo hi > /etc/yap-sandbox-test.txt", project).CombinedOutput()
	if err == nil {
		t.Fatal("write to /etc should fail")
	}
	if !strings.Contains(string(out), "Read-only file system") {
		t.Fatalf("expected read-only error, got %q", out)
	}

	out, err = SandboxWrap("echo hi > wrote.txt && cat wrote.txt", project).CombinedOutput()
	if err != nil || !strings.Contains(string(out), "hi") {
		t.Fatalf("project write: %q %v", out, err)
	}
}

// TestWrapShadowsSecretDir verifies a deny-read directory is hidden (empty)
// inside the sandbox, even when it sits under the writable project dir.
func TestWrapShadowsSecretDir(t *testing.T) {
	requireBwrap(t)
	reset()
	project := t.TempDir()
	secret := filepath.Join(project, "secrets")
	if err := os.MkdirAll(secret, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(secret, "token"), []byte("s3cr3t"), 0o600); err != nil {
		t.Fatal(err)
	}
	SetSandboxConfig(SandboxConfig{Enabled: true, DenyRead: []string{secret}})

	out, _ := SandboxWrap("cat "+filepath.Join(secret, "token")+"; echo done", project).CombinedOutput()
	if strings.Contains(string(out), "s3cr3t") {
		t.Fatalf("secret leaked: %q", out)
	}
	if !strings.Contains(string(out), "done") {
		t.Fatalf("command did not complete: %q", out)
	}
}

func TestIsWritablePath(t *testing.T) {
	reset()
	proj := t.TempDir()
	utils.SetFrontendCwd(proj)
	defer utils.SetFrontendCwd("")

	// Absolute path under the project is writable.
	if !IsWritablePath(filepath.Join(proj, "sub", "file.txt")) {
		t.Fatal("project path should be writable")
	}
	// A relative path resolves against the frontend cwd (the project).
	if !IsWritablePath("relative/file.txt") {
		t.Fatal("relative path under the project should be writable")
	}
	// The system temp dir is writable (scratch writes never prompt).
	if !IsWritablePath(filepath.Join(os.TempDir(), "x.txt")) {
		t.Fatal("temp dir should be writable")
	}
	// Anything outside the project + temp is not writable.
	if IsWritablePath("/etc/hostname") {
		t.Fatal("/etc should not be writable")
	}
	if IsWritablePath("/home/elsewhere/file.txt") {
		t.Fatal("an unrelated home path should not be writable")
	}

	// A symlink out of the project resolves outside and is not writable.
	// (The target must be genuinely outside the writable set — not another
	// temp dir, which is writable by design.)
	link := filepath.Join(proj, "escape")
	if err := os.Symlink("/etc", link); err != nil {
		t.Skip("symlinks unavailable")
	}
	if IsWritablePath(filepath.Join(link, "hostname")) {
		t.Fatal("a symlink escaping the project should not be writable")
	}
}

func TestOutsideWritableRule(t *testing.T) {
	reset()
	proj := t.TempDir()
	utils.SetFrontendCwd(proj)
	defer utils.SetFrontendCwd("")

	rule := OutsideWritableRule("writes outside the project")
	if rule.Match("") {
		t.Fatal("empty path should not match")
	}
	if rule.Match("in-project.txt") {
		t.Fatal("a path under the project should not match")
	}
	if !rule.Match("/etc/passwd") {
		t.Fatal("a path outside the project should match")
	}
}
