package tools

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
	"unicode/utf8"

	"boers.email/yap/agent/utils"
)

// searchTimeout bounds a single ripgrep run (a huge tree or a network
// mount should not hang the agent loop). rg is a single process, so
// CommandContext's kill is enough — no process-group machinery needed.
const searchTimeout = 60 * time.Second

// searchMaxCount caps matches per file, so one huge file cannot flood
// the result before the overall head-truncation applies.
const searchMaxCount = 200

type searchArgs struct {
	Pattern  string `json:"pattern" jsonschema:"description=regular expression to search for (ripgrep syntax)"`
	Path     string `json:"path,omitempty" jsonschema:"description=file or directory to search (default: current working directory)"`
	Glob     string `json:"glob,omitempty" jsonschema:"description=restrict to files matching this glob (e.g. *.go)"`
	MaxCount int    `json:"max_count,omitempty" jsonschema:"description=maximum matches per file (default 200)"`
}

func init() {
	Register("search",
		"Search files with ripgrep. Returns matching lines as path:line:content, one per line. "+
			"Output is truncated to the first 2000 lines / 50KB.",
		func(a *searchArgs) (string, string, error) { return runSearch(a) })
	// `path` can point anywhere; a secret directory is approvable, not
	// silently searched.
	Gate("search", func(a *searchArgs) string { return a.Path }, utils.SecretPathRule("searches a secret path"))
}

func runSearch(a *searchArgs) (string, string, error) {
	if strings.TrimSpace(a.Pattern) == "" {
		return "", "", fmt.Errorf("empty pattern")
	}
	a.Path = utils.ExpandHome(a.Path)
	max := a.MaxCount
	if max <= 0 {
		max = searchMaxCount
	}
	args := []string{"--line-number", "--no-heading", "--color", "never", "--max-count", fmt.Sprintf("%d", max)}
	if a.Glob != "" {
		args = append(args, "--glob", a.Glob)
	}
	args = append(args, "--", a.Pattern)
	if a.Path != "" {
		args = append(args, a.Path)
	}

	ctx, cancel := context.WithTimeout(context.Background(), searchTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "rg", args...).Output()
	if err != nil {
		if ctx.Err() != nil {
			return "", "", fmt.Errorf("rg timed out")
		}
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
			return "(no matches)", "", nil // rg exits 1 on "no matches"
		}
		return "", "", fmt.Errorf("rg: %w", err)
	}
	text := strings.TrimSuffix(string(out), "\n")
	if text == "" {
		return "(no matches)", "", nil
	}
	text, truncated := truncateHead(text)
	if truncated {
		text += "\n[truncated: narrow the search or raise max_count]"
	}
	return text, "", nil
}

// truncateHead caps s at read's limits (readMaxLines / readMaxBytes)
// from the top — grep/file listings are ordered by file, so the head is
// the relevant part. Reports whether anything was cut.
func truncateHead(s string) (string, bool) {
	truncated := false
	lines := strings.Split(s, "\n")
	if len(lines) > readMaxLines {
		lines = lines[:readMaxLines]
		truncated = true
	}
	s = strings.Join(lines, "\n")
	if len(s) > readMaxBytes {
		s = capBytes(s, readMaxBytes)
		truncated = true
	}
	return s, truncated
}

// capBytes cuts s to at most n bytes, backing off to the last rune boundary
// so a multi-byte character is never split. The result is always valid UTF-8:
// a tool result with half a rune in it makes Neovim read the transcript back
// as latin1 ('fileencodings' falls back there) and re-encode it on :write.
func capBytes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	s = s[:n]
	// DecodeLastRuneInString reports (RuneError, 1) for a truncated trailing
	// sequence; drop those bytes until the tail is a whole rune.
	for len(s) > 0 {
		if r, size := utf8.DecodeLastRuneInString(s); r == utf8.RuneError && size <= 1 {
			s = s[:len(s)-1]
			continue
		}
		break
	}
	return s
}
