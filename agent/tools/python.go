package tools

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

type pythonArgs struct {
	Code    string `json:"code" jsonschema:"description=Python 3 code to run"`
	Timeout int    `json:"timeout,omitempty" jsonschema:"description=timeout in seconds (default 120)"`
	Cwd     string `json:"cwd,omitempty" jsonschema:"description=working directory (default: the Neovim cwd)"`
}

func init() {
	Register("python",
		"Run a Python 3 script. Each call is a fresh process with no state carried between "+
			"calls, so write one self-contained script per call. Returns combined stdout/stderr and "+
			"the exit code (a non-zero exit is reported, not an error); a failed script returns its "+
			"traceback as text. Output is truncated to the LAST 2000 lines / 50KB; when truncated, "+
			"the full output is saved to a temp file. Non-interactive: stdin is /dev/null. Runs in "+
			"its own process group, killed on timeout (default 120s). Use for multi-step computation, "+
			"data transforms, and loops over many values; prefer a direct tool call for a single "+
			"simple action.",
		func(a *pythonArgs) (string, string, error) { return runPython(a) })
}

func runPython(a *pythonArgs) (string, string, error) {
	if strings.TrimSpace(a.Code) == "" {
		return "", "", fmt.Errorf("empty code")
	}
	timeout := bashDefaultTimeout
	if a.Timeout > 0 {
		timeout = time.Duration(a.Timeout) * time.Second
	}

	// Write the script to a temp file: tracebacks carry a real filename and
	// large payloads never hit `python3 -c`'s argv limit. The file is
	// removed when the run returns; only the output log outlives it (for the
	// Lua side's drain).
	script, err := os.CreateTemp("", "yap-py-*.py")
	if err != nil {
		return "", "", err
	}
	scriptPath := script.Name()
	if _, err := script.WriteString(a.Code); err != nil {
		script.Close()
		os.Remove(scriptPath)
		return "", "", err
	}
	if err := script.Close(); err != nil {
		os.Remove(scriptPath)
		return "", "", err
	}
	defer os.Remove(scriptPath)

	cmd := exec.Command("python3", scriptPath)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if a.Cwd != "" {
		if st, err := os.Stat(a.Cwd); err != nil || !st.IsDir() {
			return "", "", fmt.Errorf("working directory does not exist: %s", a.Cwd)
		}
		cmd.Dir = a.Cwd
	}
	text, err := runStreamed("python", "python3", cmd, timeout)
	if err != nil {
		return "", "", err
	}
	return text, "", nil
}
