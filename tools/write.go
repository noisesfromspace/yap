package tools

import (
	"fmt"
	"os"
	"path/filepath"
)

type writeArgs struct {
	Path    string `json:"path" jsonschema:"description=path to the file (relative or absolute)"`
	Content string `json:"content" jsonschema:"description=full content to write"`
}

func init() {
	Register("write",
		"Write content to a file. Creates the file if it doesn't exist, "+
			"overwrites if it does. Automatically creates parent directories. "+
			"For partial changes to existing files use edit instead.",
		func(a *writeArgs) (string, string, error) {
			old, readErr := os.ReadFile(a.Path)
			if readErr != nil && !os.IsNotExist(readErr) {
				return "", "", readErr
			}
			if dir := filepath.Dir(a.Path); dir != "." {
				if err := os.MkdirAll(dir, 0o755); err != nil {
					return "", "", err
				}
			}
			if err := os.WriteFile(a.Path, []byte(a.Content), 0o644); err != nil {
				return "", "", err
			}
			// Always diff, creates included (old = ""): the pitel:ui diff
			// is the visual record since long argument headers are folded.
			ui := unifiedDiff(a.Path, string(old), a.Content)
			return fmt.Sprintf("Successfully wrote %d bytes to %s", len(a.Content), a.Path), ui, nil
		})
}
