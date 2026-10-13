package utils

import (
	"encoding/json"
	"fmt"
	"strings"
)

// SlimArgs returns a compact stand-in for a tool call's arguments for
// the yap:tool header in the buffer (R-tool-region). write/edit calls can carry
// kilobytes of content that the user already sees as the yap:ui diff
// below the header, so the header — which parse_buffer flattens into
// the model's transcript on later sends — keeps only the shape
// ("[N lines]"); the file on disk is the ground truth and the full
// arguments are in the audit log (yap:event tool_call). ok is false when the
// tool is not slimmed, when the arguments do not parse, or when they do not
// carry the exact fields being summarized — a confidently wrong header
// ("[0 lines]" for a call that did write content) is worse than the raw
// arguments, which the caller then keeps verbatim.
func SlimArgs(name, argsJSON string) (args any, ok bool) {
	// lineCount reports the line count of a text block the way an editor
	// shows it: a single trailing newline terminates the last line instead
	// of starting an empty one, so "a\nb\nc\n" is 3 lines, matching the
	// yap:ui diff below the header.
	lineCount := func(s string) int {
		s = strings.TrimSuffix(s, "\n")
		if s == "" {
			return 0
		}
		return strings.Count(s, "\n") + 1
	}
	switch name {
	case "write":
		var a struct {
			Path    json.RawMessage `json:"path"`
			Content json.RawMessage `json:"content"`
		}
		if err := json.Unmarshal([]byte(argsJSON), &a); err != nil || a.Content == nil {
			return nil, false
		}
		var path, content string
		if err := json.Unmarshal(a.Path, &path); err != nil {
			return nil, false
		}
		if err := json.Unmarshal(a.Content, &content); err != nil {
			return nil, false
		}
		return map[string]any{
			"path":    path,
			"content": fmt.Sprintf("[%d lines]", lineCount(content)),
		}, true
	case "edit":
		var a struct {
			Path  json.RawMessage `json:"path"`
			Edits []struct {
				OldText json.RawMessage `json:"oldText"`
				NewText json.RawMessage `json:"newText"`
			} `json:"edits"`
		}
		if err := json.Unmarshal([]byte(argsJSON), &a); err != nil || a.Edits == nil {
			return nil, false
		}
		var path string
		if err := json.Unmarshal(a.Path, &path); err != nil {
			return nil, false
		}
		add, del := 0, 0
		for _, e := range a.Edits {
			var oldText, newText string
			if err := json.Unmarshal(e.OldText, &oldText); err != nil {
				return nil, false
			}
			if err := json.Unmarshal(e.NewText, &newText); err != nil {
				return nil, false
			}
			add += lineCount(newText)
			del += lineCount(oldText)
		}
		return map[string]any{
			"path":  path,
			"edits": fmt.Sprintf("[%d edits, +%d/-%d lines]", len(a.Edits), add, del),
		}, true
	}
	return nil, false
}
