package tools

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"boers.email/yap/agent/utils"
)

type bashArgs struct {
	Command string `json:"command" jsonschema:"description=bash command to execute"`
	Timeout int    `json:"timeout,omitempty" jsonschema:"description=timeout in seconds (default 120)"`
	Cwd     string `json:"cwd,omitempty" jsonschema:"description=working directory (default: the Neovim cwd)"`
}

func init() {
	Register("bash",
		"Execute a bash command. Runs immediately with no sandbox; high-risk commands require user confirmation. Returns combined stdout/stderr and the exit code "+
			"(a non-zero exit is reported, not an error). Output is truncated to the LAST "+
			"2000 lines / 50KB; when truncated, the full output is saved to a temp file. "+
			"Non-interactive: stdin is /dev/null. Default timeout 120s, adjustable.",
		func(a *bashArgs) (string, string, error) { return runBash(a) })
	// Deterministic floor: high-risk commands are hard-blocked (see the alert
	// gate in agent/agent.go); the decision model never downgrades these.
	Gate("bash", utils.TierAskModel, func(args json.RawMessage) string {
		var a bashArgs
		if err := json.Unmarshal(args, &a); err != nil {
			return ""
		}
		return utils.DangerousCommandReason(a.Command)
	})
}

func runBash(a *bashArgs) (string, string, error) {
	if strings.TrimSpace(a.Command) == "" {
		return "", "", fmt.Errorf("empty command")
	}
	a.Cwd = utils.ExpandHome(a.Cwd)
	timeout := utils.ToolDefaultTimeout
	if a.Timeout > 0 {
		timeout = time.Duration(a.Timeout) * time.Second
	}

	cmd := exec.Command("bash", "-c", a.Command)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // own process group
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
	text, err := utils.RunStreamed("bash", a.Command, cmd, timeout)
	if err != nil {
		return "", "", err
	}
	return text, "", nil
}
