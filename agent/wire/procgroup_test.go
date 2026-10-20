package wire

import (
	"errors"
	"os/exec"
	"syscall"
	"testing"
	"time"
)

// KillAll is the stop() safety net: it must actually take down a tracked
// process group, not just drop bookkeeping entries.
func TestKillAll(t *testing.T) {
	cmd := exec.Command("sleep", "60")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start sleep: %v", err)
	}
	Track(cmd.Process.Pid)

	KillAll()

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected sleep to be killed")
		}
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("expected ExitError, got %T: %v", err, err)
		}
		ws, ok := ee.Sys().(syscall.WaitStatus)
		if !ok || !ws.Signaled() {
			t.Fatalf("expected death by signal, got %v", ee.Sys())
		}
	case <-time.After(10 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("KillAll did not kill the tracked process group")
	}
	Untrack(cmd.Process.Pid)
}

// Untrack must remove a pgid from the kill set: after Untrack, KillAll
// leaves the process alone.
func TestUntrackPreventsKill(t *testing.T) {
	cmd := exec.Command("sleep", "60")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start sleep: %v", err)
	}
	defer func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	}()

	Track(cmd.Process.Pid)
	Untrack(cmd.Process.Pid)
	KillAll()

	// Signal 0 probes existence without delivering anything; a killed
	// process makes it fail.
	if err := cmd.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("untracked process was killed: %v", err)
	}
}
