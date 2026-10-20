package tools

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"boers.email/yap/agent/safety"
	"boers.email/yap/agent/utils"
	"boers.email/yap/agent/wire"
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

// withSandboxApproval installs an approval reply channel that answers every
// request with `approved`, and re-enables the default (unsandboxed) policy on
// cleanup.
func withSandboxApproval(t *testing.T, approved bool) {
	t.Helper()
	approvalIDs := make(chan string, 10)
	oldWriter := wire.SetFrameWriter(approvalIDWriter{ids: approvalIDs})
	oldReplies := wire.ApprovalReplies
	replies := make(chan wire.ApprovalReply)
	wire.ApprovalReplies = replies
	go func() {
		for id := range approvalIDs {
			replies <- wire.ApprovalReply{ID: id, Approved: approved}
		}
	}()
	t.Cleanup(func() {
		wire.SetFrameWriter(oldWriter)
		close(approvalIDs)
		wire.ApprovalReplies = oldReplies
		safety.SetSandboxConfig(safety.SandboxConfig{}) // back to unsandboxed for other tests
	})
}

func requireSandbox(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("bwrap not installed")
	}
}

// TestBashSandboxDenied: a write outside the allowlist (the read-only home) is
// blocked by the kernel, and the denial stands when the human refuses the
// unsandboxed re-run.
func TestBashSandboxDenied(t *testing.T) {
	requireSandbox(t)
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	withSandboxApproval(t, false)
	safety.SetSandboxConfig(safety.SandboxConfig{Enabled: true})

	target := filepath.Join(home, fmt.Sprintf("yap-sandbox-deny-%d", time.Now().UnixNano()))
	project := t.TempDir()
	r, _, err := run(t, "bash", `{"command":"echo hi > `+target+`","cwd":"`+project+`"}`)
	if err != nil {
		t.Fatalf("bash: %v", err)
	}
	if !strings.Contains(r, "Read-only file system") {
		t.Fatalf("expected read-only failure, got %q", r)
	}
	if !strings.Contains(r, "approval denied") {
		t.Fatalf("expected denial note, got %q", r)
	}
	if _, statErr := os.Stat(target); statErr == nil {
		t.Fatalf("file should not exist after denial: %s", target)
	}
}

// TestBashSandboxApproved: the same write, but the human approves the
// unsandboxed re-run, so the command executes for real.
func TestBashSandboxApproved(t *testing.T) {
	requireSandbox(t)
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	withSandboxApproval(t, true)
	safety.SetSandboxConfig(safety.SandboxConfig{Enabled: true})

	target := filepath.Join(home, fmt.Sprintf("yap-sandbox-approve-%d", time.Now().UnixNano()))
	t.Cleanup(func() { _ = os.Remove(target) })
	project := t.TempDir()
	r, _, err := run(t, "bash", `{"command":"echo approved > `+target+` && cat `+target+`","cwd":"`+project+`"}`)
	if err != nil {
		t.Fatalf("bash: %v", err)
	}
	if !strings.Contains(r, "approved") {
		t.Fatalf("expected approved re-run to write the file, got %q", r)
	}
	data, statErr := os.ReadFile(target)
	if statErr != nil || !strings.Contains(string(data), "approved") {
		t.Fatalf("file not written on approval: %v %q", statErr, data)
	}
}

// TestBashPreApprovedRunsUnsandboxed: a command that matched a static guard
// rule (e.g. `git push --force`) was already approved before it ran, so it
// runs unsandboxed — it must not hit the write barrier, which would prompt the
// human a second time for the same command.
func TestBashPreApprovedRunsUnsandboxed(t *testing.T) {
	requireSandbox(t)
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	withSandboxApproval(t, false)
	safety.SetSandboxConfig(safety.SandboxConfig{Enabled: true})

	target := filepath.Join(home, fmt.Sprintf("yap-sandbox-preapproved-%d", time.Now().UnixNano()))
	t.Cleanup(func() { _ = os.Remove(target) })
	project := t.TempDir()
	// The redirect to $HOME is the probe: it fails EROFS under the sandbox, so
	// a pre-approved (unsandboxed) run is the only way it succeeds.
	r, _, err := run(t, "bash", `{"command":"git push --force origin main > `+target+` 2>&1; echo rc=$?","cwd":"`+project+`"}`)
	if err != nil {
		t.Fatalf("bash: %v", err)
	}
	if strings.Contains(r, "Read-only file system") {
		t.Fatalf("pre-approved command should not be sandboxed: %q", r)
	}
	if _, statErr := os.Stat(target); statErr != nil {
		t.Fatalf("expected the redirect to succeed unsandboxed: %v", statErr)
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
