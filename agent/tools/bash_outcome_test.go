package tools

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"boers.email/yap/agent/wire"
)

func TestSandboxFinalOutcome(t *testing.T) {
	// Fake only the sandbox process: its write-barrier failure triggers the real
	// approval/retry path without depending on host user-namespace support.
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "bwrap"), []byte("#!/bin/sh\necho 'cp: Read-only file system'\nexit 1\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	for _, tc := range []struct {
		name, command, want string
		approved            bool
	}{
		{"retry succeeds", "printf final", "", true},
		{"retry fails", "printf final; exit 6", "exit", true},
		{"retry times out", "sleep 5", "timeout", true},
		{"denial already badged", "printf should-not-run", "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			withSandboxApproval(t, tc.approved)
			build := func() *exec.Cmd {
				cmd := exec.Command("bash", "-c", tc.command)
				cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
				return cmd
			}
			var outcome *wire.ToolOutcome
			text, err := runSandboxed(tc.command, dir, build, 30*time.Millisecond, &outcome)
			if err != nil {
				t.Fatal(err)
			}
			if tc.want == "" {
				if outcome != nil {
					t.Fatalf("stale outcome: %+v", outcome)
				}
			} else if outcome == nil || outcome.Outcome != tc.want {
				t.Fatalf("outcome: %+v", outcome)
			}
			if tc.want == "exit" && (outcome.Code == nil || *outcome.Code != 6) {
				t.Fatalf("wrong final code: %+v", outcome)
			}
			if tc.approved && strings.Contains(text, "Read-only file system") {
				t.Fatalf("first attempt leaked: %s", text)
			}
		})
	}
}
