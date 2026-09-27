package tools

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// Same limits as pi's read tool (doc: R12 result policy).
const (
	readMaxLines = 2000
	readMaxBytes = 50 * 1024
)

func init() {
	Register(&Tool{
		Name:        "read",
		Description: "Read a text file. Returns at most 2000 lines / 50KB; for large files use offset and limit.",
		Schema: `{"type":"object","properties":{
			"path":{"type":"string","description":"file to read"},
			"offset":{"type":"integer","description":"first line to return (1-based)"},
			"limit":{"type":"integer","description":"maximum number of lines"}},
			"required":["path"]}`,
		Run: func(args json.RawMessage) (string, string, error) {
			var a struct {
				Path   string `json:"path"`
				Offset int    `json:"offset"`
				Limit  int    `json:"limit"`
			}
			if err := json.Unmarshal(args, &a); err != nil {
				return "", "", err
			}
			data, err := os.ReadFile(a.Path)
			if err != nil {
				return "", "", err
			}
			lines := strings.Split(string(data), "\n")
			start := a.Offset - 1
			if start < 0 {
				start = 0
			}
			if start > len(lines) {
				return "", "", fmt.Errorf("offset %d past end of file (%d lines)", a.Offset, len(lines))
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
				text += fmt.Sprintf("\n[truncated: use offset/limit; file has %d lines total]", len(strings.Split(string(data), "\n")))
			}
			return text, "", nil
		},
	})
}
