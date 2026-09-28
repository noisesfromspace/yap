package tools

import (
	"bytes"
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
	RegisterStream("bash",
		"Execute a bash command. Returns combined stdout/stderr and the exit code "+
			"(a non-zero exit is reported, not an error). Output is truncated to the LAST "+
			"2000 lines / 50KB; when truncated, the full output is saved to a temp file. "+
			"Non-interactive: stdin is /dev/null. Default timeout 120s, adjustable.",
		func(a *bashArgs, emit StreamFunc) (string, string, error) { return runBash(a, emit) })
}

func runBash(a *bashArgs, emit StreamFunc) (string, string, error) {
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
	// interleaved like a terminal.
	out, err := os.CreateTemp("", "pitel-bash-*.log")
	if err != nil {
		return "", "", err
	}
	outPath := out.Name()
	cmd.Stdin = nil // /dev/null
	var goCopy chan struct{}
	var pr, pw *os.File
	if emit != nil {
		// Tee child output through a pipe: one copy to the temp file
		// (runaway commands must not OOM the binary), one to the chunk
		// emitter for live display.
		var pipeErr error
		pr, pw, pipeErr = os.Pipe()
		if pipeErr != nil {
			out.Close()
			os.Remove(outPath)
			return "", "", pipeErr
		}
		cmd.Stdout = pw
		cmd.Stderr = pw
		goCopy = make(chan struct{})
		cw := &chunkWriter{emit: emit}
		go func() {
			defer close(goCopy)
			io.Copy(io.MultiWriter(out, cw), pr)
			cw.flush() // the final partial line
		}()
	} else {
		cmd.Stdout = out
		cmd.Stderr = out
	}

	if err := cmd.Start(); err != nil {
		out.Close()
		os.Remove(outPath)
		if emit != nil {
			pr.Close()
			pw.Close()
			<-goCopy
		}
		return "", "", err
	}
	if emit != nil {
		// The child holds its own dup of the pipe; closing ours means
		// io.Copy sees EOF as soon as the child's fds die with it.
		// `out` must stay OPEN: the copy goroutine writes to it.
		pw.Close()
	} else {
		out.Close() // the child has its own fd
	}
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

	if emit != nil {
		// Drain the pipe. A command that leaves a background process
		// holding stdout (some-daemon &) would keep the pipe open
		// forever, so bound the wait.
		select {
		case <-goCopy:
		case <-time.After(2 * time.Second):
			pr.Close() // unblock io.Copy
			<-goCopy
		}
		pr.Close()
		out.Close()
	}

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

// chunkWriter implements io.Writer for live command output: each Write
// is buffered to line granularity and emitted through the callback at
// most every streamInterval, so a chatty build (progress bars, per-file
// lines) does not translate into a buffer redraw per chunk. The final
// partial line flushes when the pipe closes.
const streamInterval = 100 * time.Millisecond

type chunkWriter struct {
	emit StreamFunc
	buf  []byte
	last time.Time
}

func (w *chunkWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	if bytes.IndexByte(w.buf, '\n') < 0 {
		return len(p), nil
	}
	if time.Since(w.last) >= streamInterval {
		w.flush()
	}
	return len(p), nil
}

// flush emits the buffer through the last newline (or everything when
// the pipe is closing and no newline ever comes).
func (w *chunkWriter) flush() {
	if len(w.buf) == 0 {
		return
	}
	s := string(w.buf)
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		w.emit(s[:i+1])
		w.buf = w.buf[:copy(w.buf, s[i+1:])]
	} else {
		w.emit(s)
		w.buf = w.buf[:0]
	}
	w.last = time.Now()
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
