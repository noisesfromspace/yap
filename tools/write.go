package tools

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

func init() {
	Register(&Tool{
		Name: "write",
		Description: "Write content to a file. Creates the file if it doesn't exist, " +
			"overwrites if it does. Automatically creates parent directories. " +
			"For partial changes to existing files use edit instead.",
		Schema: `{"type":"object","properties":{
			"path":{"type":"string","description":"path to the file (relative or absolute)"},
			"content":{"type":"string","description":"full content to write"}},
			"required":["path","content"]}`,
		Run: func(args json.RawMessage) (string, string, error) {
			var a struct {
				Path    string `json:"path"`
				Content string `json:"content"`
			}
			if err := json.Unmarshal(args, &a); err != nil {
				return "", "", err
			}
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
			ui := ""
			if readErr == nil {
				ui = unifiedDiff(a.Path, string(old), a.Content)
			}
			return fmt.Sprintf("Successfully wrote %d bytes to %s", len(a.Content), a.Path), ui, nil
		},
	})
}
