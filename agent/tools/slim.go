package tools

import (
	"encoding/json"
	"fmt"
	"strings"
)

// SlimArgs returns a compact stand-in for a tool call's arguments for
// the yap:tool header in the buffer (R12). write/edit calls can carry
// kilobytes of content that the user already sees as the yap:ui diff
// below the header, so the header — which parse_buffer feeds back to
// the model as its own tool_calls history — keeps only the shape
// ("[N lines]"); the file on disk is the ground truth and the full
// arguments are in the audit log (yap:event tool_call). ok is false
// for tools whose arguments are small enough to keep verbatim.
func SlimArgs(name, argsJSON string) (args any, ok bool) {
	lineCount := func(s string) int {
		if s == "" {
			return 0
		}
		return strings.Count(s, "\n") + 1
	}
	switch name {
	case "write":
		var a struct {
			Path    string `json:"path"`
			Content string `json:"content"`
		}
		if err := json.Unmarshal([]byte(argsJSON), &a); err != nil {
			return nil, false
		}
		return map[string]any{
			"path":    a.Path,
			"content": fmt.Sprintf("[%d lines]", lineCount(a.Content)),
		}, true
	case "edit":
		var a struct {
			Path  string `json:"path"`
			Edits []struct {
				OldText string `json:"oldText"`
				NewText string `json:"newText"`
			} `json:"edits"`
		}
		if err := json.Unmarshal([]byte(argsJSON), &a); err != nil {
			return nil, false
		}
		add, del := 0, 0
		for _, e := range a.Edits {
			add += lineCount(e.NewText)
			del += lineCount(e.OldText)
		}
		return map[string]any{
			"path":  a.Path,
			"edits": fmt.Sprintf("[%d edits, +%d/-%d lines]", len(a.Edits), add, del),
		}, true
	}
	return nil, false
}
