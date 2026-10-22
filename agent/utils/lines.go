package utils

import (
	"fmt"
	"strings"
)

// findLineOffsets returns the byte offsets at which s appears as a complete
// line in content: the match must start at the beginning of a line and end at
// that line's newline (or end of file). s must not contain a newline.
func findLineOffsets(content, s string) []int {
	var offs []int
	lineStart := 0
	for lineStart < len(content) {
		lineEnd := strings.IndexByte(content[lineStart:], '\n')
		var line string
		var next int
		if lineEnd < 0 {
			line = content[lineStart:]
			next = len(content)
		} else {
			line = content[lineStart : lineStart+lineEnd]
			next = lineStart + lineEnd + 1
		}
		if line == s {
			offs = append(offs, lineStart)
		}
		lineStart = next
	}
	return offs
}

// ResolveSpan resolves a from/to range edit to the byte span [start, end)
// that it replaces. `from` must match a complete line exactly once; `to` is
// the first complete line equal to it at or after `from`, or "" / "<eof>" for
// end of file. end includes the `to` line's trailing newline (or is
// len(content) at end of file).
func ResolveSpan(content, from, to string) (start, end int, err error) {
	fromOffs := findLineOffsets(content, from)
	switch len(fromOffs) {
	case 0:
		return 0, 0, fmt.Errorf("from %q is not a complete line in the file", from)
	case 1:
	default:
		return 0, 0, fmt.Errorf("from %q matches %d lines in the file; include more context", from, len(fromOffs))
	}
	start = fromOffs[0]
	end = len(content)
	if to == "" || strings.EqualFold(to, "<eof>") {
		return start, end, nil
	}
	for _, off := range findLineOffsets(content, to) {
		if off > start+len(from) {
			end = off + len(to)
			if end < len(content) && content[end] == '\n' {
				end++
			}
			return start, end, nil
		}
	}
	return 0, 0, fmt.Errorf("to %q not found after from in the file", to)
}
