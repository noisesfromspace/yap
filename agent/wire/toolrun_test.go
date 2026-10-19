package wire

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"boers.email/yap/agent/utils"
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

func TestRunStreamedUsesAssetsBase(t *testing.T) {
	// When the frontend supplies a per-session assets dir, the live-tail log
	// lands there instead of the system temp dir.
	base := t.TempDir()
	utils.SetAssetsBase(base)
	defer utils.SetAssetsBase("")

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

// TestRunStreamedEmitsProgress checks that a streamed tool emits throttled
// progress frames carrying the running tool's byte/line throughput and
// elapsed time — the data the winbar shows instead of inferring time.
func TestRunStreamedEmitsProgress(t *testing.T) {
	var frames bytes.Buffer
	old := SetFrameWriter(&frames)
	defer SetFrameWriter(old)

	oldInterval := progressInterval
	progressInterval = 5 * time.Millisecond
	defer func() { progressInterval = oldInterval }()

	cmd := exec.Command("bash", "-c", "echo one; echo two; sleep 0.05")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	text, err := RunStreamed("bash", "echo one; echo two; sleep 0.05", cmd, ToolDefaultTimeout)
	if err != nil || !strings.Contains(text, "two") {
		t.Fatalf("run: %q %v", text, err)
	}

	type frame struct {
		Type  string `json:"type"`
		Tool  string `json:"tool"`
		Bytes int64  `json:"bytes"`
		Lines int64  `json:"lines"`
		Ms    int64  `json:"ms"`
	}
	var saw bool
	var last frame
	for _, line := range strings.Split(strings.TrimSpace(frames.String()), "\n") {
		var f frame
		if err := json.Unmarshal([]byte(line), &f); err != nil {
			t.Fatalf("frame not JSON: %q", line)
		}
		if f.Type == "progress" {
			saw = true
			last = f
		}
	}
	if !saw {
		t.Fatalf("no progress frame emitted: %q", frames.String())
	}
	if last.Tool != "bash" || last.Bytes <= 0 || last.Lines < 2 {
		t.Fatalf("progress frame wrong: %+v", last)
	}
}
