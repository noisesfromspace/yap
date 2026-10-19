package tools

import (
	"fmt"
	"os"
	"path/filepath"

	"boers.email/yap/agent/safety"
	"boers.email/yap/agent/utils"
)

type writeArgs struct {
	Path    string `json:"path" jsonschema:"description=path to the file (relative or absolute)"`
	Content string `json:"content" jsonschema:"description=full content to write"`
}

func init() {
	Register("write",
		"Write content to a file. Creates the file if it doesn't exist, "+
			"overwrites if it does. Automatically creates parent directories. "+
			"Writing to a secret path (~/.ssh, ~/.aws, /run/agenix, ...) pauses for user approval. "+
			"For partial changes to existing files use edit instead.",
		func(a *writeArgs) (string, string, error) {
			a.Path = utils.ExpandHome(a.Path)
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
			// Always diff, creates included (old = ""): the yap:ui diff
			// is the visual record since long argument headers are folded.
			ui := utils.UnifiedDiff(a.Path, string(old), a.Content)
			result := fmt.Sprintf("Successfully wrote %d bytes to %s", len(a.Content), a.Path)
			return result, ui, nil
		})
	// Secret paths are approvable, not silently written: pause for Run/Deny.
	Gate("write", func(a *writeArgs) string { return a.Path }, safety.SecretPathRule("writes a secret path"))
}
