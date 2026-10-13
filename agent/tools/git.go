package tools

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"boers.email/yap/agent/utils"
)

// gitTimeout bounds a single read-only git invocation.
const gitTimeout = 30 * time.Second

// gitMaxLog caps the number of commits a log call can request.
const gitMaxLog = 100

type gitArgs struct {
	Command string `json:"command" jsonschema:"description=read-only git subcommand,enum=status,enum=diff,enum=log,enum=show,enum=blame"`
	Path    string `json:"path,omitempty" jsonschema:"description=file or directory to restrict the command to (required for blame)"`
	Staged  bool   `json:"staged,omitempty" jsonschema:"description=diff against the index (staged changes) instead of the working tree"`
	Rev     string `json:"rev,omitempty" jsonschema_description:"commit, ref, or range to show/diff/log from (default HEAD)"`
	Limit   int    `json:"limit,omitempty" jsonschema:"description=max commits for log (default 10; capped at 100)"`
	Oneline bool   `json:"oneline,omitempty" jsonschema:"description=log: one line per commit"`
}

func init() {
	Register("git",
		"Inspect the git repository (read-only). Runs in the current working directory — the "+
			"project root. status: porcelain with branch + staged/unstaged/untracked files; "+
			"diff: working tree vs index (--staged for the index); log: recent commits; "+
			"show: one commit's message and diff; blame: line-by-line authorship of a file. "+
			"Output is truncated to the first 2000 lines / 50KB.",
		func(a *gitArgs) (string, string, error) { return runGit(a) })
}

func runGit(a *gitArgs) (string, string, error) {
	a.Path = utils.ExpandHome(a.Path)
	// A revision must never be parsed as an option: rev is appended before
	// the `--` path separator, so a leading dash would be consumed by git as
	// a flag (e.g. `--output=<file>` writes a file, `--ext-diff` re-enables
	// external diff drivers). No valid ref starts with "-".
	if strings.HasPrefix(a.Rev, "-") {
		return "", "", fmt.Errorf("rev must not start with '-' (got %q)", a.Rev)
	}
	// -c color.ui=never and --no-pager keep output plain and non-paged;
	// GIT_TERMINAL_PROMPT=0 guarantees a credential prompt can never hang
	// the non-interactive agent loop.
	args := []string{"-c", "color.ui=never", "--no-pager"}

	switch a.Command {
	case "status":
		args = append(args, "status", "--porcelain=v1", "--branch")
		if a.Path != "" {
			args = append(args, "--", a.Path)
		}
	case "diff":
		args = append(args, "diff", "--no-ext-diff")
		if a.Staged {
			args = append(args, "--cached")
		}
		if a.Rev != "" {
			args = append(args, a.Rev)
		}
		if a.Path != "" {
			args = append(args, "--", a.Path)
		}
	case "log":
		limit := a.Limit
		if limit <= 0 {
			limit = 10
		}
		if limit > gitMaxLog {
			limit = gitMaxLog
		}
		args = append(args, "log", "--decorate", "-n", fmt.Sprintf("%d", limit))
		if a.Oneline {
			args = append(args, "--oneline")
		}
		if a.Rev != "" {
			args = append(args, a.Rev)
		}
		if a.Path != "" {
			args = append(args, "--", a.Path)
		}
	case "show":
		rev := a.Rev
		if rev == "" {
			rev = "HEAD"
		}
		args = append(args, "show", rev)
		if a.Path != "" {
			args = append(args, "--", a.Path)
		}
	case "blame":
		if strings.TrimSpace(a.Path) == "" {
			return "", "", fmt.Errorf("blame requires a path")
		}
		args = append(args, "blame")
		if a.Rev != "" {
			args = append(args, a.Rev)
		}
		args = append(args, "--", a.Path)
	default:
		return "", "", fmt.Errorf("unknown subcommand %q (status, diff, log, show, blame)", a.Command)
	}

	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	out, err := cmd.Output()
	if err != nil {
		if ctx.Err() != nil {
			return "", "", fmt.Errorf("git timed out")
		}
		if ee, ok := err.(*exec.ExitError); ok {
			return "", "", fmt.Errorf("git %s: %s", a.Command, strings.TrimSpace(string(ee.Stderr)))
		}
		return "", "", fmt.Errorf("git: %w", err)
	}

	text := strings.TrimRight(string(out), "\n")
	switch a.Command {
	case "status":
		// porcelain prints a "## <branch>" header even when clean; a lone
		// header (no file lines) means a clean working tree.
		if text != "" && !strings.Contains(text, "\n") {
			text += "\n(clean working tree)"
		}
	case "diff":
		if text == "" {
			text = "(no changes)"
		}
	default:
		if text == "" {
			text = "(no output)"
		}
	}
	if text == "" {
		// git produced nothing and no branch header (e.g. bare/empty repo).
		return "(no output)", "", nil
	}
	text, truncated := truncateHead(text)
	if truncated {
		text += "\n[truncated: narrow the path or use limit/oneline]"
	}
	return text, "", nil
}
