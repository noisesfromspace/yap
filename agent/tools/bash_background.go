package tools

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"boers.email/yap/agent/safety"
	"boers.email/yap/agent/utils"
	"boers.email/yap/agent/wire"
)

// Bash jobs belong to the persistent serve process, not an individual turn.
// A one-shot send reaps them when its backend exits. Logs remain in the
// session assets so both completed and running jobs can be inspected.
type bashJob struct {
	id, log string
	cmd     *exec.Cmd
	done    chan struct{}
	result  string // written before done is closed
}

var bashJobs = struct {
	sync.Mutex
	next int
	jobs map[string]*bashJob
}{jobs: make(map[string]*bashJob)}

type bashOutputArgs struct {
	ID   string `json:"id" jsonschema:"description=ID returned by a background bash command"`
	Wait bool   `json:"wait,omitempty" jsonschema:"description=wait for completion; omit to inspect current output without blocking"`
	Stop bool   `json:"stop,omitempty" jsonschema:"description=stop a running background command and its process group"`
}

// A background log lives in the session assets, so the tool result itself can
// stay small: only the tail is returned to the model, and the full log stays
// readable with `read` (offset/limit) when more is needed.
const (
	bgOutputMaxLines = 200
	bgOutputMaxBytes = 8 * 1024
)

func init() {
	Register("bash_output", "Read the current output and exit status of a background bash command. Set wait=true only for a command expected to finish; stop=true kills a running command. Returns the last 200 lines / 8KB of the log; the full log is retained in session assets and can be read with the read tool.", bashOutput, closeBackgroundBash)
}

func startBackgroundBash(a *bashArgs, buildCmd func() *exec.Cmd, projectDir string, preApproved bool) (string, string, error) {
	bashJobs.Lock()
	active := 0
	for _, job := range bashJobs.jobs {
		select {
		case <-job.done:
		default:
			active++
		}
	}
	if active >= 16 {
		bashJobs.Unlock()
		return "", "", fmt.Errorf("too many running background bash commands (16)")
	}
	bashJobs.Unlock()

	log, err := os.CreateTemp(utils.AssetsBase(), "yap-bash-background-*.log")
	if err != nil {
		return "", "", err
	}
	cmd := buildCmd()
	sandboxed := safety.SandboxActive() && !preApproved
	if sandboxed {
		cmd = safety.SandboxWrap(a.Command, projectDir)
	}
	cmd.Stdin = nil
	cmd.Stdout, cmd.Stderr = log, log
	if err := cmd.Start(); err != nil {
		_ = log.Close()
		_ = os.Remove(log.Name())
		return "", "", err
	}
	wire.Track(cmd.Process.Pid)
	bashJobs.Lock()
	bashJobs.next++
	job := &bashJob{id: fmt.Sprintf("bash-%d", bashJobs.next), log: log.Name(), cmd: cmd, done: make(chan struct{})}
	bashJobs.jobs[job.id] = job
	bashJobs.Unlock()
	wire.EmitEvent(map[string]any{"type": "bash_background_start", "id": job.id, "log": job.log, "command": safety.Scrub(a.Command)})
	go func() {
		wait := make(chan error, 1)
		go func() { wait <- cmd.Wait() }()
		var runErr error
		timedOut := false
		if a.Timeout > 0 {
			timer := time.NewTimer(time.Duration(a.Timeout) * time.Second)
			select {
			case runErr = <-wait:
			case <-timer.C:
				timedOut = true
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
				runErr = <-wait
			}
			timer.Stop()
		} else {
			runErr = <-wait
		}
		_ = log.Close()
		wire.Untrack(cmd.Process.Pid)
		result := "completed"
		if runErr != nil {
			result = runErr.Error()
		}
		if timedOut {
			result = fmt.Sprintf("timed out after %ds; process group killed", a.Timeout)
		}
		if sandboxed {
			if tail, err := bashLog(job.log); err == nil && safety.SandboxViolated(tail) {
				result += "; sandbox blocked a write (run in foreground to request approval)"
			}
		}
		job.result = result
		wire.EmitEvent(map[string]any{"type": "bash_background_end", "id": job.id, "log": job.log, "status": result})
		close(job.done)
	}()
	return fmt.Sprintf("Started %s. Log: %s. Use bash_output with id=%q to inspect progress or wait for completion. The command may continue after this turn.", job.id, job.log, job.id), "", nil
}

// bashLog returns the tail of a job's log: at most bgOutputMaxLines lines and
// bgOutputMaxBytes bytes. Cut from the byte offset drops the partial first
// line, which also avoids starting mid-rune.
func bashLog(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close() //nolint:errcheck // read-only
	st, err := f.Stat()
	if err != nil {
		return "", err
	}
	truncated := st.Size() > bgOutputMaxBytes
	if truncated {
		if _, err := f.Seek(st.Size()-bgOutputMaxBytes, io.SeekStart); err != nil {
			return "", err
		}
	}
	b, err := io.ReadAll(f)
	if err != nil {
		return "", err
	}
	text := string(b)
	if truncated {
		if i := strings.IndexByte(text, '\n'); i >= 0 {
			text = text[i+1:]
		}
	}
	if lines := strings.Split(text, "\n"); len(lines) > bgOutputMaxLines {
		text = strings.Join(lines[len(lines)-bgOutputMaxLines:], "\n")
		truncated = true
	}
	if truncated {
		text = fmt.Sprintf("[truncated: showing the last %d lines; full log at %s]\n%s", bgOutputMaxLines, path, text)
	}
	if strings.TrimSpace(text) == "" {
		text = "(no output yet)"
	}
	return safety.Scrub(text), nil
}

func bashOutput(a *bashOutputArgs) (string, string, error) {
	bashJobs.Lock()
	job := bashJobs.jobs[a.ID]
	bashJobs.Unlock()
	if job == nil {
		return "", "", fmt.Errorf("unknown background bash ID %q", a.ID)
	}
	if a.Stop {
		select {
		case <-job.done:
		default:
			_ = syscall.Kill(-job.cmd.Process.Pid, syscall.SIGKILL)
		}
	}
	if a.Wait || a.Stop {
		select {
		case <-job.done:
		case <-wire.TurnContext().Done():
			return "", "", context.Canceled
		}
	}
	status := "running"
	select {
	case <-job.done:
		status = job.result
	default:
	}
	text, err := bashLog(job.log)
	if err != nil {
		return "", "", err
	}
	return fmt.Sprintf("%s: %s\n%s", job.id, status, text), "", nil
}

func closeBackgroundBash() {
	bashJobs.Lock()
	jobs := make([]*bashJob, 0, len(bashJobs.jobs))
	for _, job := range bashJobs.jobs {
		jobs = append(jobs, job)
	}
	bashJobs.Unlock()
	for _, job := range jobs {
		select {
		case <-job.done:
		default:
			_ = syscall.Kill(-job.cmd.Process.Pid, syscall.SIGKILL)
			<-job.done
		}
	}
}
