package tools

import (
	"fmt"
	"os"
	"strings"

	"boers.email/yap/agent/utils"
)

// Same limits as pi's read tool (doc: R12 result policy).
const (
	readMaxLines = 2000
	readMaxBytes = 50 * 1024
)

type readArgs struct {
	Path   string `json:"path" jsonschema:"description=file to read"`
	Offset int    `json:"offset,omitempty" jsonschema:"description=first line to return (1-based)"`
	Limit  int    `json:"limit,omitempty" jsonschema:"description=maximum number of lines"`
}

func init() {
	Register("read",
		"Read a text file. Returns at most 2000 lines / 50KB; for large files use offset and limit.",
		func(a *readArgs) (string, string, error) {
			if err := utils.GuardReadPath(a.Path); err != nil {
				return "", "", err
			}
			data, err := os.ReadFile(a.Path)
			if err != nil {
				return "", "", err
			}
			total := len(strings.Split(string(data), "\n"))
			lines := strings.Split(string(data), "\n")
			start := a.Offset - 1
			if start < 0 {
				start = 0
			}
			if start > len(lines) {
				return "", "", fmt.Errorf("offset %d past end of file (%d lines)", a.Offset, total)
			}
			lines = lines[start:]
			limit := a.Limit
			if limit <= 0 || limit > readMaxLines {
				limit = readMaxLines
			}
			truncated := false
			if len(lines) > limit {
				lines = lines[:limit]
				truncated = true
			}
			text := strings.Join(lines, "\n")
			if len(text) > readMaxBytes {
				text = text[:readMaxBytes]
				truncated = true
			}
			if truncated {
				text += fmt.Sprintf("\n[truncated: use offset/limit; file has %d lines total]", total)
			}
			return text, "", nil
		})
}
