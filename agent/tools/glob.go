package tools

import (
	"context"
	"fmt"
	"os/exec"
	"strings"

	"boers.email/yap/agent/utils"
)

type globArgs struct {
	Pattern string `json:"pattern" jsonschema:"description=glob pattern to match file paths (e.g. **/*.go)"`
	Path    string `json:"path,omitempty" jsonschema:"description=directory to search from (default: current working directory)"`
}

func init() {
	Register("glob",
		"List files matching a glob pattern (ripgrep --files: recursive, gitignore-aware, sorted). "+
			"Truncated to the first 2000 lines / 50KB.",
		func(a *globArgs) (string, string, error) { return runGlob(a) })
}

func runGlob(a *globArgs) (string, string, error) {
	if strings.TrimSpace(a.Pattern) == "" {
		return "", "", fmt.Errorf("empty pattern")
	}
	a.Path = utils.ExpandHome(a.Path)
	args := []string{"--files", "--sort", "path", "--glob", a.Pattern}
	if a.Path != "" {
		args = append(args, a.Path)
	}

	ctx, cancel := context.WithTimeout(context.Background(), searchTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "rg", args...).Output()
	if err != nil {
		if ctx.Err() != nil {
			return "", "", fmt.Errorf("rg --files timed out")
		}
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
			return "(no matches)", "", nil // rg --files exits 1 when nothing matches
		}
		return "", "", fmt.Errorf("rg --files: %w", err)
	}
	text := strings.TrimSuffix(string(out), "\n")
	if text == "" {
		return "(no matches)", "", nil
	}
	text, truncated := truncateHead(text)
	if truncated {
		text += "\n[truncated: narrow the glob]"
	}
	return text, "", nil
}
