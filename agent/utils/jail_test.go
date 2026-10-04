package utils

import (
	"os"
	"path/filepath"
	"testing"
)

// The jail must be a strict no-op when the flake's wrapper is not in play:
// an unset (or broken) env var yields the bare fallback tool.

func TestJailToolFallsBackWhenUnconfigured(t *testing.T) {
	t.Setenv("YAP_JAIL_BASH", "")
	if got := JailTool("YAP_JAIL_BASH", "bash"); got != "bash" {
		t.Fatalf("unconfigured jail returned %q, want bare fallback %q", got, "bash")
	}
}

func TestJailToolIgnoresBrokenPath(t *testing.T) {
	t.Setenv("YAP_JAIL_BASH", "/nonexistent/yap-jail-bash")
	if got := JailTool("YAP_JAIL_BASH", "bash"); got != "bash" {
		t.Fatalf("broken jail path returned %q, want bare fallback %q", got, "bash")
	}
}

func TestJailToolUsesExecutableEnvVar(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "yap-jail-bash")
	if err := os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("YAP_JAIL_BASH", script)
	if got := JailTool("YAP_JAIL_BASH", "bash"); got != script {
		t.Fatalf("got %q, want %q", got, script)
	}
}
