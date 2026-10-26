package mcp

import (
	"encoding/json"
	"strings"
	"unicode/utf8"
)

// maxResultBytes caps a tool result before it enters context and the audit
// log, matching the other content-bearing tools.
const maxResultBytes = 50 * 1024

// Text converts a raw tool result into the string sent to the model. Text
// blocks are joined; structured content is preferred over text when both
// describe the same payload (many servers return the JSON twice). Unsupported
// content blocks are summarized instead of silently dropped.
func (r Result) Text() string {
	var texts []string
	var unsupported []string
	for _, raw := range r.Content {
		var kind struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(raw, &kind) != nil {
			continue
		}
		switch kind.Type {
		case "text":
			var t struct {
				Text string `json:"text"`
			}
			if json.Unmarshal(raw, &t) == nil && t.Text != "" {
				texts = append(texts, t.Text)
			}
		case "image", "audio", "resource", "resource_link":
			unsupported = append(unsupported, kind.Type)
		}
	}

	var out string
	switch {
	case r.IsError:
		switch {
		case len(texts) > 0:
			out = "Error: " + strings.Join(texts, "\n")
		case len(r.StructuredContent) > 0:
			out = "Error: " + string(r.StructuredContent)
		default:
			out = "Error: tool failed"
		}
	case len(r.StructuredContent) > 0:
		out = string(r.StructuredContent)
	default:
		out = strings.Join(texts, "\n")
	}

	if len(unsupported) > 0 {
		out += "\n[unsupported content: " + strings.Join(unsupported, ", ") + "]"
	}

	return capUTF8(out, maxResultBytes)
}

// capUTF8 cuts s to at most n bytes, backing off to a whole rune so a
// multi-byte character is never split, then appends a notice. A result with
// half a rune in it makes Neovim read the transcript back as latin1 and
// re-encode it on :write.
func capUTF8(s string, n int) string {
	if len(s) <= n {
		return s
	}
	s = s[:n]
	for len(s) > 0 {
		if r, size := utf8.DecodeLastRuneInString(s); r == utf8.RuneError && size == 1 {
			s = s[:len(s)-1]
			continue
		}
		break
	}
	return s + "\n[truncated]"
}
