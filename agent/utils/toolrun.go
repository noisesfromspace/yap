package utils

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const (
	// ToolDefaultTimeout is the default execution limit for process-backed tools.
	ToolDefaultTimeout = 120 * time.Second
	toolMaxLines       = 2000
	toolMaxBytes       = 50 * 1024
)

// RunStreamed runs a tool process with stdout and stderr merged into a temp
// log that the Lua side follows live (tool_start/tool_end announce the log path).
// stdin is /dev/null. On timeout the whole process group is SIGKILLed. cmd
// must already have SysProcAttr.Setpgid set and its Dir validated.
func RunStreamed(name, command string, cmd *exec.Cmd, timeout time.Duration) (string, error) {
	out, err := os.CreateTemp("", "yap-"+name+"-*.log")
	if err != nil {
		return "", err
	}
	outPath := out.Name()
	EmitEvent(map[string]string{"type": "tool_start", "name": name, "log": outPath, "command": Scrub(command)})
	cmd.Stdin = nil // /dev/null
	cmd.Stdout = out
	cmd.Stderr = out

	if err := cmd.Start(); err != nil {
		out.Close()
		os.Remove(outPath)
		return "", err
	}
	out.Close()             // the child has its own fd
	pgid := cmd.Process.Pid // Setpgid: child is the group leader
	Track(pgid)
	defer Untrack(pgid)

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	timedOut := false
	select {
	case err = <-done:
	case <-time.After(timeout):
		timedOut = true
		syscall.Kill(-pgid, syscall.SIGKILL) // the whole tree
		err = <-done
	}
	// Let the Lua side drain the final bytes before an untruncated log is
	// removed; deleting it here raced the drain.
	var size int64
	if st, statErr := os.Stat(outPath); statErr == nil {
		size = st.Size()
	}
	text, truncated := readToolTail(outPath, size)
	EmitEvent(map[string]any{"type": "tool_end", "name": name, "log": outPath, "truncated": truncated})

	exit := 0
	if ee, ok := err.(*exec.ExitError); ok {
		exit = ee.ExitCode() // -1 when killed by signal
	} else if err != nil {
		os.Remove(outPath)
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

// readToolTail keeps the last lines/bytes of command output.
func readToolTail(path string, size int64) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
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
