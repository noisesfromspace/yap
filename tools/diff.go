package tools

import (
	"os"
	"os/exec"
	"strings"
)

// unifiedDiff returns "diff -u" output for old vs new content of path, or
// "" when diff(1) is unavailable or the inputs are too large. The output
// is display-only (pitel:ui) and never sent to the model, so any failure
// degrades to no ui section rather than a tool error.
func unifiedDiff(path, oldContent, newContent string) string {
	const maxDiffBytes = 512 * 1024
	if oldContent == newContent || len(oldContent)+len(newContent) > maxDiffBytes {
		return ""
	}
	diffBin, err := exec.LookPath("diff")
	if err != nil {
		return ""
	}
	old := writeTemp(oldContent)
	if old == "" {
		return ""
	}
	defer os.Remove(old)
	new := writeTemp(newContent)
	if new == "" {
		return ""
	}
	defer os.Remove(new)

	cmd := exec.Command(diffBin, "-u", "--label", "a/"+path, "--label", "b/"+path, old, new)
	out, err := cmd.Output()
	if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
		err = nil // diff exits 1 when files differ — that is the expected case
	}
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\n")
}

func writeTemp(content string) string {
	f, err := os.CreateTemp("", "pitel-diff-*")
	if err != nil {
		return ""
	}
	defer f.Close()
	if _, err := f.WriteString(content); err != nil {
		os.Remove(f.Name())
		return ""
	}
	return f.Name()
}
