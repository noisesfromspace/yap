package tools

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// pi-derived defaults (doc: R15).
const (
	bashDefaultTimeout = 120 * time.Second // Claude Code / OpenCode consensus
	bashMaxLines       = 2000
	bashMaxBytes       = 50 * 1024
)

type bashArgs struct {
	Command string `json:"command" jsonschema:"description=bash command to execute"`
	Timeout int    `json:"timeout,omitempty" jsonschema:"description=timeout in seconds (default 120)"`
	Cwd     string `json:"cwd,omitempty" jsonschema:"description=working directory (default: the Neovim cwd)"`
}

func init() {
	Register("bash",
		"Execute a bash command. Returns combined stdout/stderr and the exit code "+
			"(a non-zero exit is reported, not an error). Output is truncated to the LAST "+
			"2000 lines / 50KB; when truncated, the full output is saved to a temp file. "+
			"Non-interactive: stdin is /dev/null. Default timeout 120s, adjustable.",
		func(a *bashArgs) (string, string, error) { return runBash(a) })
}

func runBash(a *bashArgs) (string, string, error) {
	if strings.TrimSpace(a.Command) == "" {
		return "", "", fmt.Errorf("empty command")
	}
	timeout := bashDefaultTimeout
	if a.Timeout > 0 {
		timeout = time.Duration(a.Timeout) * time.Second
	}

	cmd := exec.Command("bash", "-c", a.Command)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // own process group
	if a.Cwd != "" {
		if st, err := os.Stat(a.Cwd); err != nil || !st.IsDir() {
			return "", "", fmt.Errorf("working directory does not exist: %s", a.Cwd)
		}
		cmd.Dir = a.Cwd
	}
	// Stream output to a temp file instead of accumulating in memory: a
	// runaway command must not OOM the binary. Stdout and Stderr are the
	// same *os.File, so the child gets one fd for both — output is
	// interleaved like a terminal. The file doubles as the live view:
	// announce its path and let the Lua side tail it.
	out, err := os.CreateTemp("", "yap-bash-*.log")
	if err != nil {
		return "", "", err
	}
	outPath := out.Name()
	EmitEvent(map[string]string{"type": "tool_start", "name": "bash", "log": outPath, "command": a.Command})
	cmd.Stdin = nil // /dev/null
	cmd.Stdout = out
	cmd.Stderr = out

	if err := cmd.Start(); err != nil {
		out.Close()
		os.Remove(outPath)
		return "", "", err
	}
	out.Close()             // the child has its own fd
	pgid := cmd.Process.Pid // Setpgid: child is the group leader
	track(pgid)
	defer untrack(pgid)

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
	// The log is complete; let the Lua side drain it before a small
	// (untruncated) log is removed below.
	EmitEvent(map[string]string{"type": "tool_end", "name": "bash"})

	exit := 0
	if ee, ok := err.(*exec.ExitError); ok {
		exit = ee.ExitCode() // -1 when killed by signal
	} else if err != nil {
		os.Remove(outPath)
		return "", "", fmt.Errorf("run: %w", err)
	}

	var size int64
	if st, statErr := os.Stat(outPath); statErr == nil {
		size = st.Size()
	}
	text, truncated := readTail(outPath, size)
	if truncated {
		text = fmt.Sprintf("[truncated: showing tail; full output (%d bytes) at %s]\n%s", size, outPath, text)
	} else {
		os.Remove(outPath) // no reason to keep it: the result has everything
	}
	if strings.TrimSpace(text) == "" {
		text = "(no output)"
	}
	if timedOut {
		text += fmt.Sprintf("\n[timed out after %s; process group killed]", timeout)
	}
	if exit != 0 {
		text += fmt.Sprintf("\n[exit code %d]", exit)
	}
	return text, "", nil
}

// readTail reads the end of the file at path, keeping the LAST
// bashMaxLines lines / bashMaxBytes bytes — for command output the tail
// is usually the relevant part (pi does the same for bash, while read
// truncates from the head). Reports whether anything was cut.
func readTail(path string, size int64) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	truncated := false
	if size > bashMaxBytes {
		if _, err := f.Seek(size-bashMaxBytes, io.SeekStart); err == nil {
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
	if lines := strings.Split(s, "\n"); len(lines) > bashMaxLines {
		s = strings.Join(lines[len(lines)-bashMaxLines:], "\n")
		truncated = true
	}
	return s, truncated
}
