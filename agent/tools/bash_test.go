package tools

import (
	"strings"
	"testing"
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
