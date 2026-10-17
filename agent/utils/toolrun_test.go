package utils

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestReadToolTail(t *testing.T) {
	dir := t.TempDir()

	// Small file: returned verbatim, not truncated.
	small := filepath.Join(dir, "small.log")
	if err := os.WriteFile(small, []byte("one\ntwo\nthree\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, truncated := readToolTail(small, int64(len("one\ntwo\nthree\n")))
	if truncated || got != "one\ntwo\nthree\n" {
		t.Fatalf("small: %q truncated=%v", got, truncated)
	}

	// Byte truncation: >50KB keeps the last ~50KB, drops the partial first
	// line, and reports truncated. The result must be a suffix of the file.
	var content strings.Builder
	for i := 0; content.Len() < 60*1024; i++ {
		content.WriteString(strings.Repeat(string(rune('a'+i%26)), 40))
		content.WriteByte('\n')
	}
	big := filepath.Join(dir, "big.log")
	if err := os.WriteFile(big, []byte(content.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	got, truncated = readToolTail(big, int64(content.Len()))
	if !truncated {
		t.Fatal("expected byte truncation")
	}
	if len(got) > toolMaxBytes {
		t.Fatalf("tail is %d bytes, exceeds %d", len(got), toolMaxBytes)
	}
	if !strings.HasSuffix(content.String(), got) {
		t.Fatal("tail is not a suffix of the file")
	}

	// Line truncation: more than toolMaxLines lines keeps the last
	// toolMaxLines even when the file is under the byte cap.
	var many strings.Builder
	for i := 0; i < toolMaxLines+500; i++ {
		many.WriteString("x\n")
	}
	lines := filepath.Join(dir, "lines.log")
	if err := os.WriteFile(lines, []byte(many.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	got, truncated = readToolTail(lines, int64(many.Len()))
	if !truncated {
		t.Fatal("expected line truncation")
	}
	if n := strings.Count(got, "\n"); n > toolMaxLines {
		t.Fatalf("tail has %d lines, want <= %d", n, toolMaxLines)
	}
}

func TestRunStreamedUsesTempBase(t *testing.T) {
	// When the frontend supplies a per-session tmp dir, the live-tail log
	// lands there instead of the system temp dir.
	base := t.TempDir()
	SetTempBase(base)
	defer SetTempBase("")

	cmd := exec.Command("echo", "hi")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	text, err := RunStreamed("bash", "echo hi", cmd, ToolDefaultTimeout)
	if err != nil || !strings.Contains(text, "hi") {
		t.Fatalf("run: %q %v", text, err)
	}
	logs, _ := filepath.Glob(base + "/yap-bash-*.log")
	if len(logs) != 1 {
		t.Fatalf("expected the log under the temp base, got %v", logs)
	}
	_ = os.Remove(logs[0])
}
