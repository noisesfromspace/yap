package tools

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"boers.email/yap/agent/utils"
)

type pythonArgs struct {
	Code           string `json:"code,omitempty" jsonschema:"description=Python 3 code to run (for small inline scripts; mutually exclusive with file)"`
	File           string `json:"file,omitempty" jsonschema_description:"path to a Python script to run (for larger scripts: write the file first with the write tool, then run it; mutually exclusive with code; ~ expands to the home directory)"`
	Timeout        int    `json:"timeout,omitempty" jsonschema:"description=timeout in seconds (default 120)"`
	Cwd            string `json:"cwd,omitempty" jsonschema:"description=working directory (default: the Neovim cwd)"`
	IsolateNetwork bool   `json:"isolate_network,omitempty" jsonschema:"description=run the script in a private network namespace with no connectivity (Linux only; requires util-linux unshare)"`
}

func init() {
	Register("python",
		"Run a Python 3 script. Each call is a fresh process with no state carried between "+
			"calls. Pass exactly one of code (a small inline script) or file (a script path written "+
			"with the write tool) — use file for larger scripts so the code lives in a real, editable file. "+
			"Write larger scripts under ~/.local/share/yap/scratch/ (outside the repo, gitignored); ~ is expanded "+
			"to the home directory in path fields. Returns combined stdout/stderr and the exit "+
			"code (a non-zero exit is reported, not an error); a failed script returns its traceback "+
			"as text. Output is truncated to the LAST 2000 lines / 50KB; when truncated, the full "+
			"output is saved to a temp file. Non-interactive: stdin is /dev/null. Runs in its own "+
			"process group, killed on timeout (default 120s). Use for multi-step computation, data "+
			"transforms, and loops over many values; prefer a direct tool call for a single simple "+
			"action. Scripts that use shell execution, dynamic code execution, or recursive deletion "+
			"require user confirmation.",
		func(a *pythonArgs) (string, string, error) { return runPython(a) })
	// Deterministic floor: code-exec / dynamic-exec / recursive-delete calls
	// are hard-blocked (see the alert gate in agent/agent.go).
	Gate("python", utils.TierAskModel, func(args json.RawMessage) string {
		var a pythonArgs
		if err := json.Unmarshal(args, &a); err != nil {
			return ""
		}
		src := a.Code
		if strings.TrimSpace(src) == "" && strings.TrimSpace(a.File) != "" {
			p, err := filepath.Abs(utils.ExpandHome(a.File))
			if err != nil {
				return ""
			}
			if data, err := os.ReadFile(p); err == nil {
				src = string(data)
			}
		}
		return utils.DangerousPythonReason(src)
	})
}

func runPython(a *pythonArgs) (string, string, error) {
	a.File = utils.ExpandHome(a.File)
	a.Cwd = utils.ExpandHome(a.Cwd)
	hasCode := strings.TrimSpace(a.Code) != ""
	hasFile := strings.TrimSpace(a.File) != ""
	if !hasCode && !hasFile {
		return "", "", fmt.Errorf("provide code or file")
	}
	if hasCode && hasFile {
		return "", "", fmt.Errorf("provide either code or file, not both")
	}
	timeout := utils.ToolDefaultTimeout
	if a.Timeout > 0 {
		timeout = time.Duration(a.Timeout) * time.Second
	}

	var scriptPath string
	label := "python3"
	if hasCode {
		// Inline: write the script to a temp file. Tracebacks carry a real
		// filename and large payloads never hit `python3 -c`'s argv limit.
		// The file is removed when the run returns; only the output log
		// outlives it (for the Lua side's drain).
		script, err := os.CreateTemp("", "yap-py-*.py")
		if err != nil {
			return "", "", err
		}
		scriptPath = script.Name()
		if _, err := script.WriteString(a.Code); err != nil {
			_ = script.Close()
			_ = os.Remove(scriptPath)
			return "", "", err
		}
		if err := script.Close(); err != nil {
			_ = os.Remove(scriptPath)
			return "", "", err
		}
		defer os.Remove(scriptPath) //nolint:errcheck // best-effort cleanup
	} else {
		// File: run the script in place. The path resolves like write's
		// (relative to the Neovim cwd unless absolute), so
		// `write script.py` then `python file=script.py` line up.
		absPath, err := filepath.Abs(a.File)
		if err != nil {
			return "", "", err
		}
		st, err := os.Stat(absPath)
		if err != nil {
			return "", "", fmt.Errorf("script file: %w", err)
		}
		if st.IsDir() {
			return "", "", fmt.Errorf("script path is a directory: %s", a.File)
		}
		scriptPath = absPath
		label = "python3 " + a.File
	}

	var cmd *exec.Cmd
	if a.IsolateNetwork {
		cmd = exec.Command("unshare", "--user", "--map-root-user", "--net", "python3", scriptPath)
	} else {
		cmd = exec.Command("python3", scriptPath)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// "default: the Neovim cwd" in the schema is a request-time value, not
	// this process's cwd (which is fixed at spawn and goes stale after :cd).
	if a.Cwd == "" {
		a.Cwd = utils.FrontendCwd()
	}
	if a.Cwd != "" {
		if st, err := os.Stat(a.Cwd); err != nil || !st.IsDir() {
			return "", "", fmt.Errorf("working directory does not exist: %s", a.Cwd)
		}
		cmd.Dir = a.Cwd
	}
	text, err := utils.RunStreamed("python", label, cmd, timeout)
	if err != nil {
		return "", "", err
	}
	return text, "", nil
}
