package utils

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	// ToolDefaultTimeout is the default execution limit for process-backed tools.
	ToolDefaultTimeout = 120 * time.Second
	toolMaxLines       = 2000
	toolMaxBytes       = 50 * 1024
)

// progressInterval is how often a streamed tool emits a progress frame while
// it runs (a var so tests can shorten it).
var progressInterval = 250 * time.Millisecond

// progressTracker counts the bytes and lines a streamed tool has emitted,
// for the throttled progress frames the winbar shows ("bash 12s · 48KB").
type progressTracker struct {
	bytes atomic.Int64
	lines atomic.Int64
}

func (p *progressTracker) add(b []byte) {
	p.bytes.Add(int64(len(b)))
	p.lines.Add(int64(bytes.Count(b, []byte{'\n'})))
}

func (p *progressTracker) snapshot() (int64, int64) {
	return p.bytes.Load(), p.lines.Load()
}

// RunStreamed runs a tool process with stdout and stderr merged into a temp
// log that the Lua side follows live (tool_start/tool_end announce the log path).
// stdin is /dev/null. On timeout the whole process group is SIGKILLed. cmd
// must already have SysProcAttr.Setpgid set and its Dir validated.
func RunStreamed(name, command string, cmd *exec.Cmd, timeout time.Duration) (string, error) {
	out, err := os.CreateTemp(AssetsBase(), "yap-"+name+"-*.log")
	if err != nil {
		return "", err
	}
	outPath := out.Name()
	EmitEvent(map[string]string{"type": "tool_start", "name": name, "log": outPath, "command": Scrub(command)})
	var tracker progressTracker
	cmd.Stdin = nil // /dev/null
	// Tee the child's merged output: it still lands in the temp log (the
	// durable, truncation-referenced copy), and each chunk is also framed as
	// a tool_output record so the live tail follows it in order. One pipe for
	// stdout+stderr means the bytes are interleaved exactly as produced.
	cmd.Stdout = io.MultiWriter(out, toolOutputFramer{log: outPath, tracker: &tracker})
	cmd.Stderr = cmd.Stdout

	if err := cmd.Start(); err != nil {
		_ = out.Close()
		_ = os.Remove(outPath)
		return "", err
	}
	// Emit a throttled progress frame while the tool runs, so the winbar shows
	// real output throughput instead of only wall-clock time. A timer drives it
	// (not the output) so a quiet command still reports elapsed time.
	start := time.Now()
	stop := make(chan struct{})
	go func() {
		t := time.NewTicker(progressInterval)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				b, l := tracker.snapshot()
				EmitProgress(outPath, name, b, l, time.Since(start).Milliseconds())
			}
		}
	}()
	// The copy goroutine (cmd.Stdout is a MultiWriter over this file and the
	// tool_output framer) writes to `out` until the child exits, so the file
	// must stay open until Wait drains the pipe.
	defer out.Close()
	pgid := cmd.Process.Pid // Setpgid: child is the group leader
	Track(pgid)
	defer Untrack(pgid)

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	timedOut := false
	cancelled := false
	select {
	case err = <-done:
	case <-TurnContext().Done():
		cancelled = true
		_ = syscall.Kill(-pgid, syscall.SIGKILL) // the whole tree
		err = <-done
	case <-time.After(timeout):
		timedOut = true
		_ = syscall.Kill(-pgid, syscall.SIGKILL) // the whole tree
		err = <-done
	}
	close(stop) // no progress frames after tool_end
	// Let the Lua side drain the final bytes before an untruncated log is
	// removed; deleting it here raced the drain.
	var size int64
	if st, statErr := os.Stat(outPath); statErr == nil {
		size = st.Size()
	}
	text, truncated := readToolTail(outPath, size)
	EmitEvent(map[string]any{"type": "tool_end", "name": name, "log": outPath, "truncated": truncated})

	if cancelled {
		// The turn was cancelled: the tail gets its final bytes and the log
		// is cleaned up, but the result is moot (the model will not see it).
		return "", context.Canceled
	}

	exit := 0
	if ee, ok := err.(*exec.ExitError); ok {
		exit = ee.ExitCode() // -1 when killed by signal
	} else if err != nil {
		_ = os.Remove(outPath)
		return "", fmt.Errorf("run: %w", err)
	}

	if truncated {
		text = fmt.Sprintf("[truncated: showing tail; full output (%d bytes) at %s]\n%s", size, outPath, text)
	}
	// An untruncated log is removed by the Lua side after it drains the
	// final bytes (the tool_end event above carries log + truncated).
	if strings.TrimSpace(text) == "" {
		text = "(no output)"
	}
	if timedOut {
		text += fmt.Sprintf("\n[timed out after %s; process group killed]", timeout)
	}
	if exit != 0 {
		text += fmt.Sprintf("\n[exit code %d]", exit)
	}
	return text, nil
}

// toolOutputFramer frames each chunk of a running tool's output as a
// tool_output record for the live tail (see RunStreamed's tee), and tallies
// the bytes/lines for the progress frames.
type toolOutputFramer struct {
	log     string
	tracker *progressTracker
}

func (f toolOutputFramer) Write(p []byte) (int, error) {
	EmitToolOutput(f.log, string(p))
	if f.tracker != nil {
		f.tracker.add(p)
	}
	return len(p), nil
}

// readToolTail keeps the last lines/bytes of command output.
func readToolTail(path string, size int64) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close() //nolint:errcheck // read-only: close on return
	truncated := false
	if size > toolMaxBytes {
		if _, err := f.Seek(size-toolMaxBytes, io.SeekStart); err == nil {
			truncated = true
		}
	}
	data, _ := io.ReadAll(f)
	s := string(data)
	if truncated {
		if i := strings.IndexByte(s, '\n'); i >= 0 {
			s = s[i+1:] // drop the partial first line
		}
	}
	if lines := strings.Split(s, "\n"); len(lines) > toolMaxLines {
		s = strings.Join(lines[len(lines)-toolMaxLines:], "\n")
		truncated = true
	}
	return s, truncated
}
