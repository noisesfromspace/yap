package auth

import (
	"bufio"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

type lockTestMethod struct {
	name  string
	login func(context.Context) error
	token func(context.Context) (string, error)
}

func (m lockTestMethod) Name() string                                 { return m.name }
func (m lockTestMethod) Login(ctx context.Context, _ io.Writer) error { return m.login(ctx) }
func (m lockTestMethod) Token(ctx context.Context) (string, error)    { return m.token(ctx) }
func (m lockTestMethod) ProviderOptions() map[string]any              { return nil }

func TestRegistryLocks(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	entered := make(chan struct{})
	release := make(chan struct{})
	done := make(chan error, 1)
	sentinel := errors.New("provider failure")
	Register(lockTestMethod{name: "lock-test", login: func(ctx context.Context) error {
		close(entered)
		select {
		case <-release:
			return sentinel
		case <-ctx.Done():
			return ctx.Err()
		}
	}, token: func(context.Context) (string, error) { return "ok", nil }})
	Register(lockTestMethod{name: "other-lock-test", token: func(context.Context) (string, error) { return "independent", nil }})
	defer delete(methods, "lock-test")
	defer delete(methods, "other-lock-test")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	go func() { done <- Login(ctx, "lock-test", io.Discard) }()
	<-entered
	// A token request cannot read/rotate credentials while a login writes them.
	waiting, stop := context.WithTimeout(ctx, 75*time.Millisecond)
	defer stop()
	if _, err := Token(waiting, "lock-test"); !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("contended Token = %v, want deadline exceeded", err)
	}
	if token, err := Token(ctx, "other-lock-test"); err != nil || token != "independent" {
		t.Errorf("independent method blocked: %q, %v", token, err)
	}
	close(release)
	if err := <-done; !errors.Is(err, sentinel) {
		t.Errorf("Login = %v", err)
	}
	if token, err := Token(ctx, "lock-test"); err != nil || token != "ok" {
		t.Errorf("lock not released after login error: %q, %v", token, err)
	}
	// Token errors must release the lock too.
	methods["lock-test"] = lockTestMethod{name: "lock-test", token: func(context.Context) (string, error) { return "", sentinel }}
	for range 2 {
		if _, err := Token(ctx, "lock-test"); !errors.Is(err, sentinel) {
			t.Errorf("Token = %v", err)
		}
	}
}

func TestCanceledLock(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if unlock, err := lockMethod(ctx, "test"); !errors.Is(err, context.Canceled) {
		if unlock != nil {
			unlock()
		}
		t.Fatalf("canceled lock = %v", err)
	}
	unlock, err := lockMethod(context.Background(), "test")
	if err != nil {
		t.Fatal(err)
	}
	unlock()
}

// The kernel must release locks even when a backend cannot run its defers.
func TestLockProcess(t *testing.T) {
	if os.Getenv("YAP_LOCK_HELPER") != "1" {
		return
	}
	unlock, err := lockMethod(context.Background(), "crash-test")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	_, _ = os.Stdout.WriteString("locked\n")
	time.Sleep(time.Minute)
}

func TestLockReleasedOnProcessExit(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestLockProcess$")
	cmd.Env = append(os.Environ(), "YAP_LOCK_HELPER=1")
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	scanner := bufio.NewScanner(pipe)
	if !scanner.Scan() || scanner.Text() != "locked" {
		t.Fatal("helper did not acquire lock")
	}
	info, err := os.Stat(filepath.Join(dir, "yap", "crash-test.lock"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("lock permissions = %o", info.Mode().Perm())
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = cmd.Wait()
	unlock, err := lockMethod(ctx, "crash-test")
	if err != nil {
		t.Fatalf("dead process retained lock: %v", err)
	}
	unlock()
}
