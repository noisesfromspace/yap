package tools

import (
	"bytes"
	"fmt"
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
		runBash)
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
	// Stdout and Stderr are the same writer: os/exec serializes the writes.
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	cmd.Stdin = nil // /dev/null

	if err := cmd.Start(); err != nil {
		return "", "", err
	}
	pgid := cmd.Process.Pid // Setpgid: child is the group leader
	track(pgid)
	defer untrack(pgid)

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	timedOut := false
	var err error
	select {
	case err = <-done:
	case <-time.After(timeout):
		timedOut = true
		syscall.Kill(-pgid, syscall.SIGKILL) // the whole tree
		err = <-done
	}

	exit := 0
	if ee, ok := err.(*exec.ExitError); ok {
		exit = ee.ExitCode() // -1 when killed by signal
	} else if err != nil {
		return "", "", fmt.Errorf("run: %w", err)
	}

	text, truncated := tailTruncate(buf.String())
	if truncated {
		f, terr := os.CreateTemp("", "pitel-bash-*.log")
		if terr == nil {
			f.WriteString(buf.String())
			f.Close()
			text = fmt.Sprintf("[truncated: showing tail; full output (%d bytes) at %s]\n%s", buf.Len(), f.Name(), text)
		}
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

// tailTruncate keeps the LAST bashMaxLines lines / bashMaxBytes bytes —
// for command output the tail is usually the relevant part (pi does the
// same for bash, while read truncates from the head).
func tailTruncate(s string) (string, bool) {
	if len(s) <= bashMaxBytes && strings.Count(s, "\n")+1 <= bashMaxLines {
		return s, false
	}
	if len(s) > bashMaxBytes {
		s = s[len(s)-bashMaxBytes:]
		if i := strings.IndexByte(s, '\n'); i >= 0 {
			s = s[i+1:] // drop the partial first line
		}
	}
	if lines := strings.Split(s, "\n"); len(lines) > bashMaxLines {
		s = strings.Join(lines[len(lines)-bashMaxLines:], "\n")
	}
	return s, true
}
